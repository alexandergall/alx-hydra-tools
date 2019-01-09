#!/run/current-system/sw/bin/perl

use strict;
use warnings;
use File::Basename;
use File::Path;
use File::Slurp;
use JSON::PP;
use LWP::UserAgent;

my %types = ( installer => 1, ALX => 1 );
my $dataDir = "/data";
my $installerDir = "$dataDir/installer";
my $releasesDir = "$dataDir/releases";

sub fetch {
    my ($url, $type) = @_;

    my $ua = LWP::UserAgent->new;
    $ua->default_header('Accept', $type) if defined $type;

    my $response = $ua->get($url);
    die "could not download $url: ", $response->status_line, "\n" unless $response->is_success;

    return $response->decoded_content;
}

my $type = $ARGV[0];
my $url = $ARGV[1];

die "Usage: $0 <installer|ALX> <release-url>\n" unless defined $url and exists $types{$type};

my $info = decode_json(fetch($url, 'application/json'));

my $id = $info->{id} or die;
my $name = $info->{nixname} or die;
my $evalId = $info->{jobsetevals}->[0] or die;
my $evalUrl = "http://hydra.net.switch.ch/eval/$evalId";
my $evalInfo = decode_json(fetch($evalUrl, 'application/json'));

sub copyFile {
    my ($jobName, $fileName, $tmpDir, $dstName, $overwrite) = @_;

    my $buildInfo = decode_json(fetch("$evalUrl/job/$jobName", 'application/json'));

    my $outPath = $buildInfo->{buildoutputs}->{out}->{path} or die;
    my $srcFile = $outPath . "/$fileName";
    my $dstDir = "$tmpDir/" . ($dstName // "");
    $dstDir =~ m|/$| || ($dstDir .= "/");
    my $dstFile = $dstDir . "$fileName";

    if (! -e $srcFile) {
	print STDERR "incomplete build: $srcFile does not exist\n";
	exit(1);
    }
    -d $dstDir || File::Path::make_path($dstDir);
    if (-e $dstFile and $overwrite) {
	unlink($dstFile);
    }
    if (! -e $dstFile) {
	print STDERR "copying $srcFile to $dstFile...\n";
	if (system("cp $srcFile $dstFile") != 0) {
	    File::Path::remove_tree($tmpDir);
	    die "copy failed";
	}
    }
}

sub getReleaseName {
    my $buildInfo = decode_json(fetch("$evalUrl/job/versionALX", 'application/json'));
    my $outPath = $buildInfo->{buildoutputs}->{out}->{path} or die;
    open(my $fh, $outPath) or die;
    my $releaseName = <$fh>;
    close($fh) or die;
    chomp $releaseName;
    return "nixos-$releaseName";
}

if ($type eq "ALX") {
    my $releaseId = $info->{id} or die;
    my $releaseName = getReleaseName();
    my $alxMajor = ($releaseName =~ /^nixos-(.*ALX(pre)?)/)[0];
    defined $alxMajor or die "Invalid ALX version $releaseName\n";
    my $releaseDir = "$releasesDir/$alxMajor/$releaseName";
    
    my $rev = $evalInfo->{jobsetevalinputs}->{nixpkgs}->{revision} or die;
    
    print STDERR "release is '$releaseName’ (build $releaseId), eval is $evalId, dir is '$releaseDir’, Git commit is $rev\n";
    
    if (-d $releaseDir) {
	print STDERR "release already exists\n";
    } else {
	my $tmpDir = $releaseDir . "-tmp";
	File::Path::make_path($tmpDir);
	copyFile("upgradeCommand", "alx-upgrade", $tmpDir);
	copyFile("upgradeCommand", "release-notes.txt", $tmpDir);
	copyFile("installImage", "nixos.tar.gz", $tmpDir);
	copyFile("installConfig", "config", $tmpDir);
	rename($tmpDir, $releaseDir) or die;

        my $latest = "$releasesDir/latest";
        if (-e $latest) {
            unlink($latest);
        }
        symlink($releaseDir, $latest);
    }
} else {
    my $revFile = "$dataDir/installer-rev";
    my $curRev = undef;
    if (-e $revFile) {
	$curRev = read_file($revFile) or die;
    }
    my $rev = $evalInfo->{jobsetevalinputs}->{installer}->{revision} or die;

    if (not $curRev or $rev ne $curRev) {
	print STDERR "new installer revision $rev\n";
	File::Path::make_path($installerDir);
	copyFile("nfsRootTarball", "nfsroot.tar.xz", $installerDir, undef, 1);
	copyFile("bootLoader", "boot-loader.tar.xz", $installerDir, undef, 1);
	write_file($revFile, $rev);
    }
}

exit 0;
