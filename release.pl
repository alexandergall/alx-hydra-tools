#!/run/current-system/sw/bin/perl

use strict;
use warnings;
use File::Basename;
use File::Path;
use JSON::PP;
use LWP::UserAgent;

my $releasesDir = "/data/releases";

sub fetch {
    my ($url, $type) = @_;

    my $ua = LWP::UserAgent->new;
    $ua->default_header('Accept', $type) if defined $type;

    my $response = $ua->get($url);
    die "could not download $url: ", $response->status_line, "\n" unless $response->is_success;

    return $response->decoded_content;
}

my $releaseUrl = $ARGV[0];

die "Usage: $0 <release-url>\n" unless defined $releaseUrl;

my $releaseInfo = decode_json(fetch($releaseUrl, 'application/json'));

my $releaseId = $releaseInfo->{id} or die;
my $releaseName = $releaseInfo->{nixname} or die;
my $evalId = $releaseInfo->{jobsetevals}->[0] or die;
my $evalUrl = "http://hydra.net.switch.ch/eval/$evalId";

my $alxMajor = ($releaseName =~ /^nixos-(.*ALX(pre)?)/)[0];
defined $alxMajor or die "Invalid ALX version $releaseName\n";
my $releaseDir = "$releasesDir/$alxMajor/$releaseName";
my $evalInfo = decode_json(fetch($evalUrl, 'application/json'));

my $rev = $evalInfo->{jobsetevalinputs}->{nixpkgs}->{revision} or die;

print STDERR "release is ‘$releaseName’ (build $releaseId), eval is $evalId, dir is ‘$releaseDir’, Git commit is $rev\n";

if (-d $releaseDir) {
    print STDERR "release already exists\n";
} else {
    my $tmpDir = dirname($releaseDir) . "/$releaseName-tmp";
    File::Path::make_path($tmpDir);

    sub copyFile {
        my ($jobName, $fileName, $dstName) = @_;

        my $buildInfo = decode_json(fetch("$evalUrl/job/$jobName", 'application/json'));

        my $outPath = $buildInfo->{buildoutputs}->{out}->{path} or die;
        my $srcFile = $outPath . "/$fileName";
        my $dstDir = "$tmpDir/" . ($dstName // "");
        $dstDir =~ m|/$| || ($dstDir .= "/");
        my $dstFile = $dstDir . "$fileName";

        if (! -e $srcFile) {
            print STDERR "incomplete build: $srcFile does not exist\n";
            File::Path::remove_tree($tmpDir);
            exit(1);
        }
        -d $dstDir || File::Path::make_path($dstDir);
        if (! -e $dstFile) {
            print STDERR "copying $srcFile to $dstFile...\n";
            system("cp $srcFile $dstFile") == 0
                or die "copy failed";
        }
    }

    copyFile("release", "upgrade");
    copyFile("installer.bootLoader", "bootx64.efi", "installer");
    copyFile("installer.bootLoader", "grub.cfg", "installer");
    copyFile("installer.kernel", "bzImage", "installer");
    copyFile("installer.nfsRootTarball", "nfsroot.tar.gz", "installer");
    copyFile("installTarball", "nixos.tgz");

    rename($tmpDir, $releaseDir) or die;
}

exit 0;
