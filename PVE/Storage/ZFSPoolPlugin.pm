package PVE::Storage::ZFSPoolPlugin;

use strict;
use warnings;

use IO::File;
use Net::IP;
use POSIX;

use PVE::RPCEnvironment;
use PVE::Storage::Plugin;
use PVE::Tools qw(run_command);

use base qw(PVE::Storage::Plugin);

sub type {
    return 'zfspool';
}

sub plugindata {
    return {
	content => [ {images => 1, rootdir => 1}, {images => 1 , rootdir => 1}],
	format => [ { raw => 1, subvol => 1 } , 'raw' ],
    };
}

sub properties {
    return {
	blocksize => {
	    description => "block size",
	    type => 'string',
	},
	sparse => {
	    description => "use sparse volumes",
	    type => 'boolean',
	},
	mountpoint => {
	    description => "mount point",
	    type => 'string', format => 'pve-storage-path',
	},
    };
}

sub options {
    return {
	pool => { fixed => 1 },
	blocksize => { optional => 1 },
	sparse => { optional => 1 },
	nodes => { optional => 1 },
	disable => { optional => 1 },
	content => { optional => 1 },
	bwlimit => { optional => 1 },
	mountpoint => { optional => 1 },
    };
}

# static zfs helper methods

sub zfs_parse_zvol_list {
    my ($text) = @_;

    my $list = ();

    return $list if !$text;

    my @lines = split /\n/, $text;
    foreach my $line (@lines) {
	my ($dataset, $size, $origin, $type, $refquota) = split(/\s+/, $line);
	next if !($type eq 'volume' || $type eq 'filesystem');

	my $zvol = {};
	my @parts = split /\//, $dataset;
	next if scalar(@parts) < 2; # we need pool/name
	my $name = pop @parts;
	my $pool = join('/', @parts);

	next unless $name =~ m!^(vm|base|subvol|basevol)-(\d+)-(\S+)$!;
	$zvol->{owner} = $2;

	$zvol->{pool} = $pool;
	$zvol->{name} = $name;
	if ($type eq 'filesystem') {
	    if ($refquota eq 'none') {
		$zvol->{size} = 0;
	    } else {
		$zvol->{size} = $refquota + 0;
	    }
	    $zvol->{format} = 'subvol';
	} else {
	    $zvol->{size} = $size + 0;
	    $zvol->{format} = 'raw';
	}
	if ($origin !~ /^-$/) {
	    $zvol->{origin} = $origin;
	}
	push @$list, $zvol;
    }

    return $list;
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^(((base|basevol)-(\d+)-\S+)\/)?((base|basevol|vm|subvol)-(\d+)-\S+)$/) {
	my $format = ($6 eq 'subvol' || $6 eq 'basevol') ? 'subvol' : 'raw';
	my $isBase = ($6 eq 'base' || $6 eq 'basevol');
	return ('images', $5, $7, $2, $4, $isBase, $format);
    }

    die "unable to parse zfs volume name '$volname'\n";
}

# virtual zfs methods (subclass can overwrite them)

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    my $cfg_mountpoint = $scfg->{mountpoint};

    # ignore failure, pool might currently not be imported
    my $mountpoint;
    eval {
	my $res = $class->zfs_get_properties($scfg, 'mountpoint', $scfg->{pool}, 1);
	$mountpoint = PVE::Storage::Plugin::verify_path($res, 1) if defined($res);
    };

    if (defined($cfg_mountpoint)) {
	if (defined($mountpoint) && !($cfg_mountpoint =~ m|^\Q$mountpoint\E/?$|)) {
	    warn "warning for $storeid - mountpoint: $cfg_mountpoint " .
		 "does not match current mount point: $mountpoint\n";
	}
    } else {
	$scfg->{mountpoint} = $mountpoint;
    }

    return;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $path = '';
    my $mountpoint = $scfg->{mountpoint} // "/$scfg->{pool}";

    if ($vtype eq "images") {
	if ($name =~ m/^subvol-/ || $name =~ m/^basevol-/) {
	    $path = "$mountpoint/$name";
	} else {
	    $path = "/dev/zvol/$scfg->{pool}/$name";
	}
	$path .= "\@$snapname" if defined($snapname);
    } else {
	die "$vtype is not allowed in ZFSPool!";
    }

    return ($path, $vmid, $vtype);
}

sub zfs_request {
    my ($class, $scfg, $timeout, $method, @params) = @_;

    my $cmd = [];

    if ($method eq 'zpool_list') {
	push @$cmd, 'zpool', 'list';
    } elsif ($method eq 'zpool_import') {
	push @$cmd, 'zpool', 'import';
	$timeout = 15 if !$timeout || $timeout < 15;
    } else {
	push @$cmd, 'zfs', $method;
    }
    push @$cmd, @params;

    my $msg = '';
    my $output = sub { $msg .= "$_[0]\n" };

    $timeout = PVE::RPCEnvironment->is_worker() ? 60*60 : 5 if !$timeout;

    run_command($cmd, errmsg => "zfs error", outfunc => $output, timeout => $timeout);

    return $msg;
}

sub zfs_wait_for_zvol_link {
    my ($class, $scfg, $volname, $timeout) = @_;

    my $default_timeout = PVE::RPCEnvironment->is_worker() ? 60*5 : 10;
    $timeout = $default_timeout if !defined($timeout);

    my ($devname, undef, undef) = $class->path($scfg, $volname);

    for (my $i = 1; $i <= $timeout; $i++) {
	last if -b $devname;
	die "timeout: no zvol device link for '$volname' found after $timeout sec found.\n"
	    if $i == $timeout;

	sleep(1);
    }
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $volname = $name;

    if ($fmt eq 'raw') {

	die "illegal name '$volname' - should be 'vm-$vmid-*'\n"
	    if $volname && $volname !~ m/^vm-$vmid-/;
	$volname = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt)
	    if !$volname;

	$class->zfs_create_zvol($scfg, $volname, $size);
	$class->zfs_wait_for_zvol_link($scfg, $volname);

    } elsif ( $fmt eq 'subvol') {

	die "illegal name '$volname' - should be 'subvol-$vmid-*'\n"
	    if $volname && $volname !~ m/^subvol-$vmid-/;
	$volname = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt)
	    if !$volname;

	die "illegal name '$volname' - should be 'subvol-$vmid-*'\n"
	    if $volname !~ m/^subvol-$vmid-/;

	$class->zfs_create_subvol($scfg, $volname, $size);

    } else {
	die "unsupported format '$fmt'";
    }

    return $volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my (undef, $name, undef) = $class->parse_volname($volname);

    $class->zfs_delete_zvol($scfg, $name);

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    $cache->{zfs} = $class->zfs_list_zvol($scfg) if !$cache->{zfs};
    my $zfspool = $scfg->{pool};
    my $res = [];

    if (my $dat = $cache->{zfs}->{$zfspool}) {

	foreach my $image (keys %$dat) {

	    my $info = $dat->{$image};

	    my $volname = $info->{name};
	    my $parent = $info->{parent};
	    my $owner = $info->{vmid};

	    if ($parent && $parent =~ m/^(\S+)\@__base__$/) {
		my ($basename) = ($1);
		$info->{volid} = "$storeid:$basename/$volname";
	    } else {
		$info->{volid} = "$storeid:$volname";
	    }

	    if ($vollist) {
		my $found = grep { $_ eq $info->{volid} } @$vollist;
		next if !$found;
	    } else {
		next if defined ($vmid) && ($owner ne $vmid);
	    }

	    push @$res, $info;
	}
    }
    return $res;
}

sub zfs_get_properties {
    my ($class, $scfg, $properties, $dataset, $timeout) = @_;

    my $result = $class->zfs_request($scfg, $timeout, 'get', '-o', 'value',
				     '-Hp', $properties, $dataset);
    my @values = split /\n/, $result;
    return wantarray ? @values : $values[0];
}

sub zfs_get_pool_stats {
    my ($class, $scfg) = @_;

    my $available = 0;
    my $used = 0;

    my @lines = $class->zfs_get_properties($scfg, 'available,used', $scfg->{pool});

    if($lines[0] =~ /^(\d+)$/) {
	$available = $1;
    }

    if($lines[1] =~ /^(\d+)$/) {
	$used = $1;
    }

    return ($available, $used);
}

sub zfs_create_zvol {
    my ($class, $scfg, $zvol, $size) = @_;

    # always align size to 1M as workaround until
    # https://github.com/zfsonlinux/zfs/issues/8541 is solved
    my $padding = (1024 - $size % 1024) % 1024;
    $size = $size + $padding;

    my $cmd = ['create'];

    push @$cmd, '-s' if $scfg->{sparse};

    push @$cmd, '-b', $scfg->{blocksize} if $scfg->{blocksize};

    push @$cmd, '-V', "${size}k", "$scfg->{pool}/$zvol";

    $class->zfs_request($scfg, undef, @$cmd);
}

sub zfs_create_subvol {
    my ($class, $scfg, $volname, $size) = @_;

    my $dataset = "$scfg->{pool}/$volname";

    my $cmd = ['create', '-o', 'acltype=posixacl', '-o', 'xattr=sa',
	       '-o', "refquota=${size}k", $dataset];

    $class->zfs_request($scfg, undef, @$cmd);
}

sub zfs_delete_zvol {
    my ($class, $scfg, $zvol) = @_;

    my $err;

    for (my $i = 0; $i < 6; $i++) {

	eval { $class->zfs_request($scfg, undef, 'destroy', '-r', "$scfg->{pool}/$zvol"); };
	if ($err = $@) {
	    if ($err =~ m/^zfs error:(.*): dataset is busy.*/) {
		sleep(1);
	    } elsif ($err =~ m/^zfs error:.*: dataset does not exist.*$/) {
		$err = undef;
		last;
	    } else {
		die $err;
	    }
	} else {
	    last;
	}
    }

    die $err if $err;
}

sub zfs_list_zvol {
    my ($class, $scfg) = @_;

    my $text = $class->zfs_request($scfg, 10, 'list', '-o', 'name,volsize,origin,type,refquota', '-t', 'volume,filesystem', '-Hrp');
    my $zvols = zfs_parse_zvol_list($text);
    return undef if !$zvols;

    my $list = ();
    foreach my $zvol (@$zvols) {
	my $pool = $zvol->{pool};
	my $name = $zvol->{name};
	my $parent = $zvol->{origin};
	if($zvol->{origin} && $zvol->{origin} =~ m/^$scfg->{pool}\/(\S+)$/){
	    $parent = $1;
	}

	$list->{$pool}->{$name} = {
	    name => $name,
	    size => $zvol->{size},
	    parent => $parent,
	    format => $zvol->{format},
            vmid => $zvol->{owner},
        };
    }

    return $list;
}

sub zfs_get_latest_snapshot {
    my ($class, $scfg, $volname) = @_;

    my $vname = ($class->parse_volname($volname))[1];

    # abort rollback if snapshot is not the latest
    my @params = ('-t', 'snapshot', '-o', 'name', '-s', 'creation');
    my $text = $class->zfs_request($scfg, undef, 'list', @params);
    my @snapshots = split(/\n/, $text);

    my $recentsnap;
    foreach (@snapshots) {
        if (/$scfg->{pool}\/$vname/) {
            s/^.*@//;
            $recentsnap = $_;
        }
    }

    return $recentsnap;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $total = 0;
    my $free = 0;
    my $used = 0;
    my $active = 0;

    eval {
	($free, $used) = $class->zfs_get_pool_stats($scfg);
	$active = 1;
	$total = $free + $used;
    };
    warn $@ if $@;

    return ($total, $free, $used, $active);
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my (undef, $vname, undef, undef, undef, undef, $format) =
        $class->parse_volname($volname);

    my $attr = $format eq 'subvol' ? 'refquota' : 'volsize';
    my $value = $class->zfs_get_properties($scfg, $attr, "$scfg->{pool}/$vname");
    if ($value =~ /^(\d+)$/) {
	return $1;
    }

    die "Could not get zfs volume size\n";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $vname = ($class->parse_volname($volname))[1];

    $class->zfs_request($scfg, undef, 'snapshot', "$scfg->{pool}/$vname\@$snap");
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $vname = ($class->parse_volname($volname))[1];

    $class->deactivate_volume($storeid, $scfg, $vname, $snap, {});
    $class->zfs_request($scfg, undef, 'destroy', "$scfg->{pool}/$vname\@$snap");
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $vname = ($class->parse_volname($volname))[1];

    $class->zfs_request($scfg, undef, 'rollback', "$scfg->{pool}/$vname\@$snap");
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $recentsnap = $class->zfs_get_latest_snapshot($scfg, $volname);

    die "can't rollback, no snapshots exist at all\n"
	if !defined($recentsnap);

    die "can't rollback, '$snap' is not most recent snapshot\n"
	if $snap ne $recentsnap;

    return 1;
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $zpath = "$scfg->{pool}/$name";

    my $snaps = [];

    my $cmd = ['zfs', 'list', '-r', '-H', '-S', 'name', '-t', 'snap', '-o',
	       'name', $zpath];

    my $outfunc = sub {
	my $line = shift;

	if ($line =~ m/^\Q$zpath\E@(.*)$/) {
	    push @$snaps, $1;
	}
    };

    eval { run_command( [$cmd], outfunc => $outfunc , errfunc => sub{}); };

    # return an empty array if dataset does not exist.
    return $snaps;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Note: $scfg->{pool} can include dataset <pool>/<dataset>
    my $pool = $scfg->{pool};
    $pool =~ s!/.*$!!;

    my $pool_imported = sub {
	my @param = ('-o', 'name', '-H', "$pool");
	my $res = eval { $class->zfs_request($scfg, undef, 'zpool_list', @param) };
	if ($@) {
	    warn "$@\n";
	    return undef;
	}
	return defined($res) && $res =~ m/$pool/;
    };

    if (!$pool_imported->()) {
	# import can only be done if not yet imported!
	my @param = ('-d', '/dev/disk/by-id/', '-o', 'cachefile=none', "$pool");
	eval { $class->zfs_request($scfg, undef, 'zpool_import', @param) };
	if (my $err = $@) {
	    # just could've raced with another import, so recheck if it is imported
	    die "could not activate storage '$storeid', $@\n" if !$pool_imported->();
	}
    }
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    return 1 if defined($snapname);

    my (undef, $dataset, undef, undef, undef, undef, $format) = $class->parse_volname($volname);

    if ($format eq 'raw') {
	$class->zfs_wait_for_zvol_link($scfg, $volname);
    } elsif ($format eq 'subvol') {
	my $mounted = $class->zfs_get_properties($scfg, 'mounted', "$scfg->{pool}/$dataset");
	if ($mounted !~ m/^yes$/) {
	    $class->zfs_request($scfg, undef, 'mount', "$scfg->{pool}/$dataset");
	}
    }

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    $snap ||= '__base__';

    my ($vtype, $basename, $basevmid, undef, undef, $isBase, $format) =
        $class->parse_volname($volname);

    die "clone_image only works on base images\n" if !$isBase;

    my $name = $class->find_free_diskname($storeid, $scfg, $vmid, $format);

    if ($format eq 'subvol') {
	my $size = $class->zfs_request($scfg, undef, 'list', '-Hp', '-o', 'refquota', "$scfg->{pool}/$basename");
	chomp($size);
	$class->zfs_request($scfg, undef, 'clone', "$scfg->{pool}/$basename\@$snap", "$scfg->{pool}/$name", '-o', "refquota=$size");
    } else {
	$class->zfs_request($scfg, undef, 'clone', "$scfg->{pool}/$basename\@$snap", "$scfg->{pool}/$name");
    }

    return "$basename/$name";
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my $snap = '__base__';

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        $class->parse_volname($volname);

    die "create_base not possible with base image\n" if $isBase;

    my $newname = $name;
    if ( $format eq 'subvol' ) {
	$newname =~ s/^subvol-/basevol-/;
    } else {
	$newname =~ s/^vm-/base-/;
    }
    my $newvolname = $basename ? "$basename/$newname" : "$newname";

    $class->zfs_request($scfg, undef, 'rename', "$scfg->{pool}/$name", "$scfg->{pool}/$newname");

    my $running  = undef; #fixme : is create_base always offline ?

    $class->volume_snapshot($scfg, $storeid, $newname, $snap, $running);

    return $newvolname;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $new_size = int($size/1024);

    my (undef, $vname, undef, undef, undef, undef, $format) =
        $class->parse_volname($volname);

    my $attr = $format eq 'subvol' ? 'refquota' : 'volsize';

    # align size to 1M so we always have a valid multiple of the volume block size
    if ($format eq 'raw') {
	my $padding = (1024 - $new_size % 1024) % 1024;
	$new_size = $new_size + $padding;
    }

    $class->zfs_request($scfg, undef, 'set', "$attr=${new_size}k", "$scfg->{pool}/$vname");

    return $new_size;
}

sub storage_can_replicate {
    my ($class, $scfg, $storeid, $format) = @_;

    return 1 if $format eq 'raw' || $format eq 'subvol';

    return 0;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	snapshot => { current => 1, snap => 1},
	clone => { base => 1},
	template => { current => 1},
	copy => { base => 1, current => 1},
	sparseinit => { base => 1, current => 1},
	replicate => { base => 1, current => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;

    if ($snapname) {
	$key = 'snap';
    } else {
	$key = $isBase ? 'base' : 'current';
    }

    return 1 if $features->{$feature}->{$key};

    return undef;
}

sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots) = @_;

    die "unsupported export stream format for $class: $format\n"
	if $format ne 'zfs';

    die "$class storage can only export snapshots\n"
	if !defined($snapshot);

    my $dataset = ($class->parse_volname($volname))[1];

    my $fd = fileno($fh);
    die "internal error: invalid file handle for volume_export\n"
	if !defined($fd);
    $fd = ">&$fd";

    # For zfs we always create a replication stream (-R) which means the remote
    # side will always delete non-existing source snapshots. This should work
    # for all our use cases.
    my $cmd = ['zfs', 'send', '-Rpv'];
    if (defined($base_snapshot)) {
	my $arg = $with_snapshots ? '-I' : '-i';
	push @$cmd, $arg, $base_snapshot;
    }
    push @$cmd, '--', "$scfg->{pool}/$dataset\@$snapshot";

    run_command($cmd, output => $fd);

    return;
}

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;

    my @formats = ('zfs');
    # TODOs:
    # push @formats, 'fies' if $volname !~ /^(?:basevol|subvol)-/;
    # push @formats, 'raw' if !$base_snapshot && !$with_snapshots;
    return @formats;
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $base_snapshot, $with_snapshots, $allow_rename) = @_;

    die "unsupported import stream format for $class: $format\n"
	if $format ne 'zfs';

    my $fd = fileno($fh);
    die "internal error: invalid file handle for volume_import\n"
	if !defined($fd);

    my (undef, $dataset, $vmid) = $class->parse_volname($volname);
    my $zfspath = "$scfg->{pool}/$dataset";
    my $suffix = defined($base_snapshot) ? "\@$base_snapshot" : '';
    my $exists = 0 == run_command(['zfs', 'get', '-H', 'name', $zfspath.$suffix],
				  noerr => 1, quiet => 1);
    if (defined($base_snapshot)) {
	die "base snapshot '$zfspath\@$base_snapshot' doesn't exist\n" if !$exists;
    } elsif ($exists) {
	die "volume '$zfspath' already exists\n" if !$allow_rename;
	warn "volume '$zfspath' already exists - importing with a different name\n";
	$dataset = $class->find_free_diskname($storeid, $scfg, $vmid, $format);
	$zfspath = "$scfg->{pool}/$dataset";
    }

    eval { run_command(['zfs', 'recv', '-F', '--', $zfspath], input => "<&$fd") };
    if (my $err = $@) {
	if (defined($base_snapshot)) {
	    eval { run_command(['zfs', 'rollback', '-r', '--', "$zfspath\@$base_snapshot"]) };
	} else {
	    eval { run_command(['zfs', 'destroy', '-r', '--', $zfspath]) };
	}
	die $err;
    }

    return "$storeid:$dataset";
}

sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $base_snapshot, $with_snapshots) = @_;

    return $class->volume_export_formats($scfg, $storeid, $volname, undef, $base_snapshot, $with_snapshots);
}

1;
