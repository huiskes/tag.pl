#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  make_thumbs.pl
#
#  DESCRIPTION:  generates thumbnail images
#       AUTHOR:  Mark Huiskes (MH), <mark.huiskes@liacs.nl>
#      COMPANY:  Universiteit Leiden
#    COPYRIGHT:  HUISKES
#      LICENSE:  Artistic 2.0, see LICENSE file
#===============================================================================

use strict;
use warnings;
use Readonly;
use Carp;
use Fatal qw( open close );
use Sort::Naturally qw ( nsort );
use Image::Magick;
use File::Basename;

use strict;

Readonly my $IM_DIR           => 'C:\Users\Mark\Databases\mirflickr';
Readonly my $THUMBS_DIR       => "$IM_DIR\\tagsession\\thumbnails";
Readonly my $THUMB_WIDTH      => 160;
Readonly my $THUMB_HEIGHT     => $THUMB_WIDTH;

Readonly my $USE_LIST_FILE        => 0;
Readonly my $LIST_FILE            => 'images.txt';
Readonly my $USE_IN_NAME_PATTERN  => 0; # not implemented yet
Readonly my $IN_NAME_PATTERN      => '';
Readonly my $IN_EXTENSION         => 'jpg';
Readonly my $USE_OUT_NAME_PATTERN => 0; # else use original file names
Readonly my $THUMB_SUFFIX         => "_t$THUMB_WIDTH"; # appended to original file names; not used in pattern
Readonly my $OUT_NAME_PATTERN     => 't';
Readonly my $OUT_EXTENSION        => 'jpg';

# user must make sure directories exist
# use mkpath of File::Path if you want to create directory recursively

# image names
my @im_files;
if (!$IN_NAME_PATTERN) {
    @im_files = nsort(glob "$IM_DIR\\*.$IN_EXTENSION");
} else {
    croak "This is not implemented yet\n";
}

# create file with list of images
if ($USE_LIST_FILE) {
    open my $imlist_fh, '>', $LIST_FILE;
    for my $im (@im_files) {
        print {$imlist_fh} "$im\n";
    }
    close $imlist_fh;
}

my ($image, $x);
$image = Image::Magick->new;
my $i = 0; # image counter
my ($base, $dir, $ext);
my $out_fname;
for my $im_name (@im_files) {
    $x = $image->Read($im_name);
    carp "$x" if "$x";

    # filter=>{Point, Box, Triangle, Hermite, Hanning, Hamming, Blackman, Gaussian, 
    # Quadratic, Cubic, Catrom, Mitchell, Lanczos, Bessel, Sinc} 
    # there's also a resample function

    $x = $image->Resize(width => $THUMB_WIDTH, height => $THUMB_HEIGHT, filter=> 'Cubic');
    carp "$x" if "$x";

    ($base, $dir, $ext) = fileparse($im_name, qr/\.[^.]*/x);
    if ($USE_OUT_NAME_PATTERN) {
        $i++;  
        $out_fname = "$THUMBS_DIR\\$OUT_NAME_PATTERN"."$i.$OUT_EXTENSION";

        # use format if you want fixed length names
    } else {
        $out_fname = "$THUMBS_DIR\\$base$THUMB_SUFFIX.$OUT_EXTENSION";
    }
    $x = $image->Write($out_fname);
    carp "$x" if "$x";
    print "$base => $out_fname\n"; 
    @$image = (); # delete the image (list) but not the object
}
