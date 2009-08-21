#!/usr/bin/perl 
#===============================================================================
#
#         FILE:  tag.pl
#
#  DESCRIPTION:  fast tagging tool
#       AUTHOR:  Mark Huiskes, <mark.huiskes@liacs.nl>
#      COMPANY:  Leiden University
#    COPYRIGHT:  HUISKES 2009
#      LICENSE:  Artistic 2.0, see LICENSE file
#===============================================================================

use strict;
use warnings;
use Carp;
use File::Copy;
use Fatal qw( open close copy move);
use List::Util;
use List::MoreUtils qw( firstidx );
use Sort::Naturally qw( nsort );
use File::Basename;
use POSIX;
use Tk;
use Tk::JPEG;
use Tk::ROText;
use Tk::JComboBox;

# configuration
my $CONFIG_FNAME = 'config.txt';

my %config;
my @config_vars = qw(MODE IM_DIR EXTENSION OUT_DIR SESSION_DIR THUMBS_DIR IM_LIST_FNAME SUBSET_FNAME 
                     N_ROWS N_COLS THUMB_SIZE DELAY TAGS_FNAME POSITION_FNAME LOG_OFFSET_X 
                     LOG_OFFSET_Y LOG_WIDTH LOG_LINES N_TAG_COLUMNS COLUMN_WIDTH AUTONEXT_CHAR 
                     VIEW_OFFSET SINGLE_PADDING GRID_PADDING SELECT_BORDER_WIDTH SELECT_BORDER_COLOR 
                     THUMB_EXTENSION THUMB_SUFFIX);
# derived variable                     
my $GRID; # from MODE 

my @im_list;          # list of (long) image filenames
my @thumb_list;       # list of (long) thumbnail filenames
my @subset;           # subset of images for current session
my $n_images;         # number of images
my $n_subset;         # number of images in subset
my %tags;             # maps tag numbers to tags
my %images_for;       # keeps anonymous hash of tagged image numbers for each tag key 
my $im_i;             # current image index (starts at 1)
my $subset_i;         # current subset image index (at 0)
my $position_fname;   # filename of file storing current position
my %tag_keys;         # hash of keys to anonymous hash of tag numbers
                      # zero key indicates automatic next-image command after keypress 
my $active_tag;       # for grid view mode only: currently active tag

# interface
my $mw;               # main window 
my $iw;               # image window
my $log;              # log widget
my $entry;            # input widget
my $input;            # text input
my $message;          # input message text widget
my $photo;            # single view image
my $imlab;            # label that holds image in single view mode
my $n_display;        # number of images in grid view
my @cbtn;             # checkbuttons for grid images
my @state;            # checkbutton states
my @thmbs;            # thumbnail images
my $active_tag_combo;
my $default_color;    # no-tag color
my $empty_photo;  
my $clock;            # autoforward clock
my $clock_on;         # flags if autoforward clock is running
my $delay;            # delay (in ms) for autoforward

my $cmd_dispatch =
{
    n          => \&next_image,
    P          => \&next_image,
    space      => \&next_image,
    p          => \&prev_image,
    N          => \&prev_image,
    q          => \&quit,
    G          => \&goto_im,
    h          => \&help,
    s          => \&show_image_tags,
    T          => \&tag_by_number,
    d          => \&delete_tag_cmd,
    A          => \&toggle_autoforward,
    plus       => \&delay_down, # increase speed
    equal      => \&delay_down, 
    minus      => \&delay_up,   # decrease speed
    underscore => \&delay_up,   
};

read_config();
# test_config();

validate_image_set(); # -> @im_list
set_subset();         # -> @subset
read_tag_file();      # -> %tags
setup_index_files();  # -> %images_for
set_start_image();    # -> $im_i, $subset_i
setup_interface();    
MainLoop();

# sections below:
# - interface
# - navigation/interface commands
# - tag commands
# - session setup
# - log output functions
# - miscellanea

#===============================================================================
# interface

sub setup_interface {
    # setup main log console window
    $mw = MainWindow->new(-title => 'Tag');
    my $wx = int($mw->screenwidth  * $config{LOG_OFFSET_X});
    my $wy = int($mw->screenheight * $config{LOG_OFFSET_Y});
    my $ww = int($mw->screenwidth  * $config{LOG_WIDTH});

    # window position
    $mw->geometry("+$wx+$wy");
    
    # canvas with line: hack to get console to right width- 
    # one of few widgets that easily takes width in pixels
    my $can = $mw->Canvas(-width =>$ww, -height => 0);
    $can->createLine(0, 0, $ww, 0);           
    $can->pack(-side => 'bottom'); 

    # entry widget
    $entry=$mw->Entry(-state => 'disabled')->pack(-side => 'bottom', -fill => 'x');
    $entry->bind('<Key-Return>', sub { $input = $entry->get() });

    # message widget
    $message = $mw->ROText(-height => 1, -relief => 
        'groove')->pack(-side => 'bottom', -fill => 'x');

    # log widget
    $log = $mw->Scrolled("ROText", -scrollbars => 'e', -height => $config{LOG_LINES}, 
        -relief => 'groove')->pack(-side => 'top', -fill => 'x');
    # don't use the 'oe' scrollbar option because scrollbar doesn't appear in time (Tk bug?)
    $log->bind('<KeyPress>' => \&key_pressed);
    
    # welcome message
    tprint("tag 2.0 (Mark Huiskes, August 2009)\n");
    tprint("- press h for help\n\n");

    tprint("Total set : $n_images images\n");
    tprint("Subset    : $n_subset images\n\n");

    # setup view window
    $iw = $mw->Toplevel( );
    $iw->resizable(0, 0); # no user resizing
    $photo = $mw->Photo;

    if (!$GRID) { # single view
        $imlab = $iw->Label( )->pack(-side => 'top');
        redraw_image();
    }
    else {
        $n_display = $config{N_COLS} * $config{N_ROWS};

        # create grid view window
        $iw->geometry("+$config{VIEW_OFFSET}+$config{VIEW_OFFSET}");
        $iw->resizable(0, 0);
        my $f1 = $iw->Frame->pack(-side => 'top');

        # setup checkbutton widgets to hold images
        my $size = $config{THUMB_SIZE} + $config{SELECT_BORDER_WIDTH}; 
        my $ii;
        for (my $i = 0; $i < $config{N_ROWS}; $i++) {
            for (my $j = 0; $j < $config{N_COLS}; $j++) {
                $ii = $i * $config{N_COLS} + $j;
                $state[$ii] = -1;
                $cbtn[$ii] = $f1->Checkbutton(-width => $size, -height => $size, 
                    -indicatoron => 0, -borderwidth => 0, -relief => 'flat', 
                    -variable => \$state[$ii], -command => \&grid_click);
            }
        }
        $default_color = $cbtn[0]->cget(-bg);

        # put checkbuttons on the frame
        for (my $i = 0; $i < $config{N_ROWS}; $i++) {
            $cbtn[$i * $config{N_COLS}]->grid(@cbtn[($i * $config{N_COLS} + 1)..(($i + 1) 
                * $config{N_COLS} - 1)], -padx => $config{GRID_PADDING}, 
                -pady => $config{GRID_PADDING});
        }

        # initialize with empty photos
        for (my $i = 0; $i < $config{N_ROWS}; $i++) {
            for (my $j = 0; $j < $config{N_COLS}; $j++) {
                $thmbs[$i * $config{N_COLS} + $j] = $iw->Photo; # re-used for each grid display
            }
        }

        my $f2 = $iw->Frame->pack(-side => 'top', -fill => 'x');

        # determine initial active tag
        my @tag_numbers = sort {$a <=> $b} keys %tags;
        $active_tag = $tag_numbers[0];

        # prev button
        my $prev_btn = $f2->Button(-text => 'Previous', 
            -command => \&prev_grid)->pack(-side => 'left', 
            -expand => 1, -fill => 'x');

        # active tag combo
        my @choices = @tags{sort {$a <=> $b} keys %tags};
        
        $active_tag_combo = $f2->JComboBox(-choices => \@choices, -updownselect => 0, 
            -selectcommand => \&active_tag_select )->pack(-side => 'left', -expand => 1, 
            -fill => 'x');
        # note: -autofind interferes with other key commands        
        # could probably temporarily disable them
        $active_tag_combo->setSelectedIndex( $active_tag - 1 );
        
        # next button
        my $next_btn = $f2->Button(-text => 'Next', -command => 
            \&next_grid)->pack(-side => 'left', -expand => 1, -fill => 'x');

        redraw_grid();
    }

    # bind keypress event
    $iw->bind('<KeyPress>' => \&key_pressed);

    $empty_photo = $iw->Photo(-width => $config{THUMB_SIZE} + $config{SELECT_BORDER_WIDTH}, 
        -height => $config{THUMB_SIZE} + $config{SELECT_BORDER_WIDTH});

    # autoforward
    $clock_on = 0;    
    $delay = $config{DELAY};
    return;
}

sub prev_grid {
    tprint("p\n");
    prev_image();
    return;
}

sub next_grid {
    tprint("n\n");
    next_image();
    return;
}

sub grid_click {
    # determine which checkbox was pressed; must be a better way to do this...
    my $cbtn = $Tk::widget;
    my $buttonstring = $cbtn->{_TkValue_};
    my $id;
    if ($buttonstring =~ /checkbutton(\d+)$/x) {
        $id = $1;
    }
    else {
        $id = 0;
    }
    
    # toggle highlighting
    my ($sbc, $dc) = ($config{SELECT_BORDER_COLOR}, $default_color);
    if ($subset_i + $id < $n_subset) {
        if ($state[$id] == 1) { # state id is set by Tk
            $cbtn[$id]->configure(-background => $sbc, -activebackground => $sbc, -selectcolor => $sbc);
        } 
        else {
            $cbtn[$id]->configure(-background => $dc, -activebackground => $dc, -selectcolor => $dc);
        }
    }

    # update tag file
    if ($subset_i + $id < $n_subset) {
        if ($state[$id] == 1) { # add image to tag index
            tprint(" <add-click>\n");
            add_tag($active_tag, $subset[$subset_i + $id]);
            tprint(">");
        }
        else  { # delete image from tag index
            tprint(" <delete-click>\n");
            delete_tag($active_tag, $subset[$subset_i + $id]);
            tprint(">");
        }
    }
    return;
}
        
sub display_thumbnails {  
    my ($sbc, $dc) = ($config{SELECT_BORDER_COLOR}, $default_color);
    my $fname = $im_list[$im_i - 1]; 
    $iw->title("$fname ($im_i)");
    my ($ii, $subset_ii, $im_ii); 
    for (my $i = 0; $i < $config{N_ROWS}; $i++) {
        for (my $j = 0; $j < $config{N_COLS}; $j++) {
            $ii = $i * $config{N_COLS} + $j;
            $subset_ii = $subset_i + $ii;
            $im_ii = $subset[$subset_ii];
            if ($subset_ii < $n_subset) { 
                # load image
                $thmbs[$ii]->configure(-file => $thumb_list[$im_ii - 1]);
                # put it on the checkbutton
                $cbtn[$ii]->configure( -image => $thmbs[$ii]);
                if (defined($images_for{$active_tag}->{$im_ii})) {
                    $state[$ii] = 1;
                    $cbtn[$ii]->configure(-background => $sbc, -activebackground => $sbc, -selectcolor => $sbc);
                }
                else {
                    $state[$ii] = 0;
                    $cbtn[$ii]->configure(-background => $dc, -activebackground => $dc, -selectcolor => $dc);
                }
            }
            else {
                # don't know better way to get rid of the photo...
                # bitmap needed for case that you start program in very last display...
                $cbtn[$ii]->configure(-bitmap => 'transparent', -image => $empty_photo, 
                    -background => $dc, -activebackground => $dc, -selectcolor => $dc);
                $state[$ii] = 0;
            }
        }
    }
    return;
}

sub get_input {
    my $message_string = shift;
    my $color = $message->cget(-bg);
    $message->configure(-bg => 'green');
    $message->insert('end', $message_string);
    $entry->configure(-state => 'normal'); 
    $entry->focus;    
    $entry->grabGlobal;
    $mw->waitVariable(\$input);
    $entry->grabRelease;
    $entry->delete(0, 'end');
    $message->delete("1.0", 'end');
    $message->configure(-bg => $color);
    $entry->configure(-state => 'disable');
    $log->focus;
    return;
}

sub key_pressed {
    my ($widget) = @_;
    my $e = $widget->XEvent; # get event object
    my $keytext = $e->K;
    if (exists $cmd_dispatch->{$keytext}) {
        my $print_key = $keytext;
        $print_key = ' <->' if ($keytext eq 'minus') || ($keytext eq 'underscore');
        $print_key = ' <+>' if ($keytext eq 'plus') || ($keytext eq 'equal');
        $print_key = ' <space>' if $keytext eq 'space';        
        tprint("$print_key\n");        
        $cmd_dispatch->{$keytext}->();
    }
    else {
        if (exists $tag_keys{$keytext}) {
            tprint("$keytext\n");                
            tag_by_press($keytext);
        }
        else {
            if ($keytext =~ /^\w$/x) {
                tprint("- $keytext is not a command or tag key; press h for help\n");
                tprint(">");
            }
        }
    }
    return;
}

sub display_image {        
    my $fname = $im_list[$im_i - 1]; 
    $photo->configure(-file => $fname);
    my $ww = $photo->width + $config{SINGLE_PADDING};
    my $wh = $photo->height + $config{SINGLE_PADDING};
    $iw->geometry("$ww"."x$wh"."+$config{VIEW_OFFSET}+$config{VIEW_OFFSET}");
    $iw->title("$fname ($im_i)");
    $imlab->configure(-width => $ww, -height => $wh, -image => $photo);
    return;
}

sub redraw_image {
    # display image
    display_image();
    
    # overwrite position file
    write_position();
	
	# print image header
	print_image_header();
    tprint(">");
    return;
}

sub redraw_grid {
    # display image
    display_thumbnails();

	# overwrite position file
	write_position();

	# print image header
	print_image_header();
    tprint(">");
    return;
}

sub write_position {
	open my $fh_position, '>', $position_fname;
	print {$fh_position} $im_i;
	close $fh_position;
    return;
}

sub toggle_autoforward {
    if (!$clock_on) {
        start_clock();           
        tprint("- autoforward turned on\n");
        tprint(">");
    }
    else {  
        stop_clock();        
        tprint("- autoforward turned off\n");
        tprint(">");
    }
    return;
}

sub delay_up {
    my $clock_was_on = $clock_on;
    stop_clock();
    $delay += 1000;
    my $delay_in_secs = $delay / 1000;
    tprint("- new autoforward delay: $delay_in_secs sec\n");
    tprint(">");
    if ($clock_was_on) {
        start_clock();
    }
    return;
}

sub delay_down {
    my $clock_was_on = $clock_on;
    stop_clock();
    $delay -= 1000;
    my $delay_in_secs = $delay / 1000;
    tprint("- new autoforward delay: $delay_in_secs sec\n");
    tprint(">");
    if ($clock_was_on) {
        start_clock();
    }
    return;
}

sub auto_forward_image {
    tprint(" (autoforward)\n");
    next_image();
    return;
}

sub active_tag_select {
    $active_tag = $_[1] + 1; # second argument is index of selected item
    tprint("NEW ACTIVE TAG ====> Updated active to tag $active_tag: $tags{$active_tag}\n");            
    redraw_grid();
    return;
}

# (interface)
#===============================================================================

#===============================================================================
# navigation/interface commands

sub prev_image {
    if ($GRID) {
        if ($subset_i > 0) {
            $subset_i = max(0, $subset_i - $n_display);
            $im_i = $subset[$subset_i];
        }
        else {
            tprint("- AT FIRST IMAGE!!!!\n");
        }
        redraw_grid();
    }
    else {
        if ($subset_i > 0) {
            $subset_i--;
            $im_i = $subset[$subset_i];
        }
        else {
            tprint("- AT FIRST IMAGE!!!!\n");
        }
        redraw_image();
    }    
    if ($clock_on) {
        start_clock(); # reset the clock
    }
    return;
}

sub next_image {
    if ($GRID) {
        if ($subset_i < $n_subset - $n_display) {
            $subset_i += $n_display;
            $im_i = $subset[$subset_i];
            if ($clock_on) {
                start_clock(); # reset the clock
            }
        }
        else {
            tprint("- AT LAST IMAGE!!!!\n");
            if ($clock_on) {
                stop_clock(); # reset the clock
                tprint("- autoforward turned off\n");
            }
        }
        redraw_grid();        
    }
    else {
        if ($subset_i < $#subset) {
            $subset_i++;
            $im_i = $subset[$subset_i];
            if ($clock_on) {
                start_clock(); # reset the clock
            }
        }
        else {
            tprint("- AT LAST IMAGE!!!!\n");
            if ($clock_on) {
                stop_clock(); # reset the clock
                tprint("- autoforward turned off\n");
            }
        }
        redraw_image();
    }
    return;
}

sub quit {
    if ($clock_on) {
        stop_clock(); # reset the clock
        tprint("- autoforward turned off\n");
    }
    # re-sort the index files
	my $index_fh;
	for my $tag_i (keys %tags) {
		my $index_fname = "$config{OUT_DIR}\\$tags{$tag_i}.txt";
                
        # make a backup copy of the index file 
        my $index_fname_copy = "$config{OUT_DIR}\\.$tags{$tag_i}.bak";
        copy($index_fname, $index_fname_copy);

        # overwrite index file with index in memory
        open $index_fh, '>', $index_fname;
        for my $ims_i (sort {$a <=> $b} keys %{$images_for{$tag_i}}) {
            print {$index_fh} "$ims_i\n";
        }
        close $index_fh;

        # delete the backup file
        unlink $index_fname_copy;
        print "$index_fname - sorted, ok.\n" ;
	}
    exit;
}

sub goto_im {
    if ($clock_on) {
        stop_clock(); # reset the clock
        tprint("- autoforward turned off\n");
    }
	get_input("Goto image number: ");
   
    if (($input >= 1) && ($input <= $n_images)) { 
		$im_i = nearest_image($input);
	    $subset_i = firstidx { $_ == $im_i } @subset;
	}
	else {
		tprint("- $input is not a valid image number\n");
	}
    if ($GRID) {
        redraw_grid();
    }
    else {    
        redraw_image();
    }
    return;
}

sub help {
    print_tags();
	print_help();
    print_keys();
    tprint(">");
    return;
}

# (navigation/interface commands)
#===============================================================================

#===============================================================================
# tag commands

sub add_tag {
	my ($tag_i, $im_i) = @_;
    # note $im_i masks global $im_i so this function can also be used in GRID-mode
	if (!defined($images_for{$tag_i}->{$im_i})) {
		# update index in memory
		$images_for{$tag_i}->{$im_i} = 1;
		# append image to index file
		my $index_fname = "$config{OUT_DIR}\\$tags{$tag_i}.txt";
		open my $index_fh, '>>', $index_fname;
		print {$index_fh} "$im_i\n";
		close $index_fh;
	    tprint("TAG ====> Updated tagfile for tag $tag_i ($tags{$tag_i}), image: $im_i\n");
	}
	else {
		tprint("- Note: tag already existed\n");
	}
    return;
}

sub tag_by_number {
    my $clock_was_on = $clock_on;
    stop_clock();
    get_input("Enter tag number: ");
    if (!$GRID) {
        if ($input =~ /\d/x) {
            add_tag($input, $im_i);
            tprint(">");
        }
        else {
            tprint("- Not a number\n");
            tprint(">");
        }
    }
    else { # grid view
        if (exists $tags{$input}) {
            $active_tag = $input;
            $active_tag_combo->setSelectedIndex($active_tag - 1);
            
            tprint("NEW ACTIVE TAG ====> Updated active to tag $active_tag: $tags{$active_tag}\n");            
            redraw_grid();
        }
        else {
            tprint("- Not a valid tag number\n");
            tprint(">");
        }
    }
    if ($clock_was_on) {
        start_clock();
    }
    return;
}

sub tag_by_press {
    my ($key) = @_;    
    my @tag_is;
    if (!$GRID) {
        # determine tag number linked to key
        @tag_is = sort {$a <=> $b} keys %{$tag_keys{$key}};
        my $autonext_char = 0;
        if ($tag_is[0] == 0) {
            $autonext_char = 1;
            shift @tag_is;
        }
        # update tag files
        for my $tag_i (@tag_is) {
            add_tag($tag_i, $im_i);
        }
        # display next image if key has autonext property 
        if ($autonext_char) {
            next_image();
        }
        else {
            tprint(">");        
        }
    }
    else { # grid view
        # use key to set active tag
        @tag_is = keys %{$tag_keys{$key}}; # no sorting this time
        shift @tag_is if ($tag_is[0] == 0);        
        if ($active_tag ne $tag_is[0]) {        
            $active_tag = $tag_is[0];
            #$active_tag_label->configure(-text => "Active tag: $tags{$active_tag}"); 
            $active_tag_combo->setSelectedIndex($active_tag - 1);
            tprint("NEW ACTIVE TAG ====> Updated active to tag $active_tag: $tags{$active_tag}\n");
            redraw_grid();
        }
        else {
            tprint("- Active tag is already set to tag $active_tag: $tags{$active_tag}\n");
            tprint(">");        
        }
    }
    return;
}

sub delete_tag_cmd {
    if (!$GRID) {
        my $clock_was_on = $clock_on;
        stop_clock();
        get_input("Enter tag number/name: ");
        if ($input =~ /\d/x) {
            delete_tag($input, $im_i);
        }
        else {
            my %rtags = reverse %tags;
            if (exists $rtags{$input}) {
                my $tag_number = $rtags{$input};
                delete_tag($tag_number, $im_i);
            }
            else {
                tprint("- Not a number\n");
            }
        }
        if ($clock_was_on) {
            start_clock();
        }
    }
    else {
        tprint("- No delete command in grid mode. Re-click image to delete tag\n");
    }
    tprint(">");
    return;
}

sub delete_tag {
    my ($tag_i, $im_i) = @_;
    if (defined($images_for{$tag_i}->{$im_i})) {
        # update index in memory
        delete $images_for{$tag_i}->{$im_i};
        
        my $index_fname = "$config{OUT_DIR}\\$tags{$tag_i}.txt";
        
        # make a backup copy of the index file 
        my $index_fname_copy = "$config{OUT_DIR}\\.$tags{$tag_i}.bak";
        copy($index_fname, $index_fname_copy);

        # overwrite index file with index in memory
        open my $index_fh, '>', $index_fname;
        for my $ims_i (sort {$a <=> $b} keys %{$images_for{$tag_i}}) {
            print {$index_fh} "$ims_i\n";
        }
        close $index_fh;

        # delete the backup file
        unlink $index_fname_copy;
        tprint("DELETED TAG ====> Updated tagfile for tag $tag_i: $tags{$tag_i}\n");
    }
    else {
        tprint("- Note: tag did not exist\n");
    }
    return;
}

# (tag commands)
#===============================================================================

#===============================================================================
# session setup

sub read_config {
    # build config dispatch; keep here for now
    my %config_dispatch;
    $config_dispatch{'MODE'} = sub {  my ($var, $val) = @_; $GRID = ($val eq 'grid') ? 1 : 0 };
    for my $var (@config_vars) {
        next if ($var eq 'MODE');            
        $config_dispatch{$var} = \&set_var;
    }

    # read config file
    open my $fh_config, '<', $CONFIG_FNAME;
	while (<$fh_config>) {
		chomp;
        next if /^#/; # skip comments
        next if /^(\s)*$/x; # skip empty lines
        s/^\s+//gx; # remove leading space
        my ($directive, $rest) = split /[=\s]+/x, $_, 2; # split on spaces or equal sign(s)
        my @vars;
		if (exists $config_dispatch{$directive}) {
            # substitute variables if they exist
            @vars = $rest =~ /(\$ \w+)/gx if $rest;
            if (@vars) {
                for my $var (@vars) {
                    my $var_directive = $var; $var_directive =~ s/\$//gx;
                    $var =~ s/\$/\\\$/gx; # replace $ by \$
                    if (exists $config{$var_directive}) {
                        $rest =~ s/$var/$config{$var_directive}/gx; 
                    }
                }    
            }
            # could have called set_var() directly with current config
            $config_dispatch{$directive}->($directive, $rest); 
        } 
        else {
            croak "Unrecognized directive $directive on line $. of $CONFIG_FNAME; aborting";
        }
	}
    close $fh_config;
    return;
}

sub set_var { 
    my ($var, $val) = @_;     
    if ($val) { 
        $config{$var} = $val;
    } 
    else { 
        $config{$var} = ""; 
    }
    return;
}

sub set_subset {
    # cannot be called directly from config: first main set needs to be validated
    if ($config{SUBSET_FNAME} eq "") {
        @subset = (1 .. $n_images);
        $n_subset = $n_images;
    }
    else {
        my $subset_fname = "$config{OUT_DIR}\\$config{SUBSET_FNAME}";
        if (-f $subset_fname) {
            # read starting image
            open my $fh_subset, '<', $subset_fname;
            while (<$fh_subset>) {
                chomp;
                push @subset, $_;
            }
            close $fh_subset;
        }
        else {
            # create starting image file
            croak "index file does not exist\n";
        }
        $n_subset = scalar @subset;
    }
    return;
}

sub validate_image_set {
    # check if file with list of images already exists
    print ("- validating image set\n");
    my $im_list_fname = "$config{SESSION_DIR}\\$config{IM_LIST_FNAME}";
    if (-e $im_list_fname) {
        # read images from list
        open my $im_list_fh, '<', $im_list_fname;
        while (<$im_list_fh>) {
            chomp;
            push @im_list, $_;        
        }
        close $im_list_fh;

        # too slow:
        # check if image list is consistent with current configuration
        #my @im_list2 = nsort(glob "$config{IM_DIR}\\*.$config{EXTENSION}");
        #if (!compare_arrays(\@im_list, \@im_list2)) {
        #   print("Warning: current image list not consistent with image directory and extension\n");
        #}
        $n_images = scalar @im_list;        
        if (!$n_images) {
           croak "No images- please check $CONFIG_FNAME\n";
        }
    }
    else {
        # create image list based on configuration
        # # create file with list of images
        @im_list = nsort(glob "$config{IM_DIR}\\*.$config{EXTENSION}");
        $n_images = scalar @im_list;        
        if ($n_images) {
            # don't write empty image list file
            open my $im_list_fh, '>', $im_list_fname;
            for my $im (@im_list) {
                print {$im_list_fh} "$im\n";
            }
            close $im_list_fh;
        }
        else {
            croak "No images- please check config.txt\n";
        }
    }

    if ($GRID) {
        # thumbnails of right size and name must be generated externally
        # e.g. with included make_thumbs.pl; names: [original name]_t[size]
        my ($base, $dir, $ext);
        my $thumb_fname;
        for my $im (@im_list) {
            ($base, $dir, $ext) = fileparse($im, qr/\.[^.]*/x);
            $thumb_fname = "$config{THUMBS_DIR}\\$base$config{THUMB_SUFFIX}.$config{THUMB_EXTENSION}";
            push @thumb_list, $thumb_fname;
        }
        # check if thumbnails exist; to save time check only first and last
        if ((!-e $thumb_list[0]) || (!-e $thumb_list[$#thumb_list])) {
            croak "Thumbnail $thumb_fname does not exist; generate thumbnails first!\n";
        }
    }    
    print ("- image set ok\n");
    return;
}

sub set_start_image {
    $subset_i = 0;
    $im_i = $subset[$subset_i]; # NOTE: $im_i refers to indices in original set
    $position_fname = "$config{SESSION_DIR}\\$config{POSITION_FNAME}";
    if (-f $position_fname) {
        # read starting image
        open my $fh_position, '<', $position_fname;
        chomp($im_i = <$fh_position>);
        # determine subset_i: index of $im_i in @subset
        $subset_i = firstidx { $_ == $im_i } @subset;
        close $fh_position;
    }
    else {
        # create starting image file
        open my $fh_position, '>', $position_fname;
        print {$fh_position} "$im_i\n";
        close $fh_position;
    }
    return;
}

sub read_tag_file {
	if (!(-d $config{SESSION_DIR})) {
		croak "$config{SESSION_DIR} does not exist!\n";
	}
	my $fh;
    my $autonext_char;
	my $tags_fname = "$config{SESSION_DIR}/$config{TAGS_FNAME}";
	if (-f $tags_fname) { 
		open $fh, '<', $tags_fname;
		while (<$fh>) {
			chomp;
            $autonext_char = 0; # flags if $config{AUTONEXT_CHAR} present
			if ($_ !~ /^\s*$/x) { # allow empty lines at end of file
				my ($tag_i, $tag_string, $key_string) = split /\s+/x, $_;
				
                # process $tag_i
                if (substr($tag_i, -1, 1) eq $config{AUTONEXT_CHAR}) {
                    $autonext_char = 1;   
                    chop $tag_i;
                }
                if ($tag_i !~ /\d+/x) {
					croak "Invalid tag file format.\n".'Use: "tag# tag_string key_string" (see manual.txt)' . "\n"; 
				}
				$tags{$tag_i} = $tag_string;

                if (($tag_i >= 1) && ($tag_i <=9)) {
                    if (exists $tag_keys{$tag_i}) {
                        croak "Invalid tag file format. Tag number $tag_i is not unique!\n";
                    }
                    else {
                        if ($autonext_char) {
                            $tag_keys{$tag_i}->{0} = 1;
                            $tag_keys{$tag_i}->{$tag_i} = 1;
                        }
                        else {
                            $tag_keys{$tag_i}->{$tag_i} = 1;
                        }
                    }
                }

                # process key string
                my $key;
                $key_string = reverse $key_string; # allows chop to get one character at a time
                while ($key_string) {                    
                    $key = chop $key_string;
                    if ($key eq $config{AUTONEXT_CHAR}) {
                        croak "Invalid tag file format. Do not put $config{AUTONEXT_CHAR} first in key string for tag $tag_i!\n";
                    }
                    if (exists $cmd_dispatch->{$key}) {
                        croak "Invalid tag file. Key $key is already in use as a command\n";
                    }
                    if ($key =~ /\d/x) {
	    				croak "Invalid tag file. Do not use digits in key string of tag $tag_i\n"; 
    				}

                    $tag_keys{$key}->{$tag_i} = 1;
                    if (substr($key_string, -1, 1) eq $config{AUTONEXT_CHAR}) {
                        chop $key_string;
                        $tag_keys{$key}->{0} = 1; # note: a single $config{AUTONEXT_CHAR} after the key anywhere is sufficient
                    }
                }
			}
		}
		close $fh;
	}
	else {
		croak "No $tags_fname file. Please create one in $config{SESSION_DIR} or change session directory.\n";
    }
    return;
}

sub setup_index_files {
	if (!(-d $config{OUT_DIR})) {
		croak "$config{OUT_DIR} does not exist!\n";
	}
	my $index_fh;
    my ($sorted, $prev); # to check if index file is sorted
	for my $tag_i (keys %tags) {
		my $index_fname_bak = "$config{OUT_DIR}\\$tags{$tag_i}.bak";
        if (-f $index_fname_bak) {
            croak "In previous session $index_fname_bak was generated.\nPlease resolve manually first!!\n";
        }
		my $index_fname = "$config{OUT_DIR}\\$tags{$tag_i}.txt";
		if (-f $index_fname) {
			# read values 
            $sorted = 1; $prev = 0;
			open $index_fh, '<', $index_fname;
			while (<$index_fh>) {
				chomp;
				$images_for{$tag_i}->{$_} = 1;
                if ($_ < $prev) {
                    $sorted = 0;
                }
                $prev = $_;
			}
			close $index_fh;
            if (!$sorted) {
                print "Index file $index_fname was not sorted.\nWill be fixed at end of current session.\n";
            } 
		}
		else {
			# create an empty file ready for appending
			open $index_fh, '>', $index_fname;
			close $index_fh;
		}
	}
    return;
}

sub test_config {
    for my $var (@config_vars) {
        print "$var: $config{$var}\n";
    }
    return;
}

# (session setup)
#===============================================================================

#===============================================================================
# log output functions

sub print_tags {
	tprint("- tags\n");
	my @tag_is = sort {$a <=> $b} keys %tags;
    my @tag_labels = @tags{@tag_is}; 
    tcolumn_print(\@tag_is, \@tag_labels, $config{N_TAG_COLUMNS}, length(max(@tag_is)), $config{COLUMN_WIDTH});
    return;
}

sub print_keys {
    tprint("- extra keys\n");
    # key data
    my (@key_names, @tags_strings);
    my $max_length = 0; # max length in @tags_strings
    my $tags_string; 
    my $first;
    for my $key_name (keys %tag_keys) { # for each key ...
        if ($key_name !~ /\d/x) {
            push @key_names, $key_name;
            $first = 1;            
            $tags_string = "";
            for my $tag_i (sort {$a <=> $b} keys %{$tag_keys{$key_name}}) { # ... add tags to $tags_string
                if ($tag_i) {# skip zero
                    if ($first || (!$GRID)) {
                        $tags_string .= "$tags{$tag_i} ";
                        $first = 0;
                    }
                    else { # grid view
                        $tags_string .= "($tags{$tag_i}) ";
                    }
                }
            }
            chop $tags_string;
            if (length($tags_string) > $max_length) {
                $max_length = length($tags_string);
            }
            push @tags_strings, $tags_string;
        }
    }
    tcolumn_print(\@key_names, \@tags_strings, $config{N_TAG_COLUMNS}, 1, max($config{COLUMN_WIDTH}, $max_length));
    return;
}

sub print_image_header {
	tprint("- \@image $im_i\n");
    return;
}

sub print_help {
    if (!$GRID) {
        tprint("- navigation\n");
        tprint("n/P/<space>      : next image\n");
        tprint("N/p              : previous image\n");
        tprint("G                : goto (nearest) image (in subset)\n");
        tprint("A                : toggle autoforward\n");
        tprint("+                : increase autoforward speed\n");
        tprint("-                : decrease autoforward speed\n");
        tprint("q                : quit\n");
        tprint("- tagging\n");
        tprint("1-9 + extra keys : fast tagging\n");
        tprint("T                : tag (for tag id's >9)\n");
        tprint("d                : delete tag\n");
        tprint("s                : show image tags\n");
    } 
    else {
        tprint("- navigation\n");
        tprint("n/P/<space>      : next display\n");
        tprint("N/p              : previous display\n");
        tprint("G                : goto (nearest) image (sets top left image of display)\n");
        tprint("A                : toggle autoforward\n");
        tprint("+                : increase autoforward speed\n");
        tprint("-                : decrease autoforward speed\n");
        tprint("q                : quit\n");
        tprint("- tagging\n");
        tprint("mouse            : image click toggles tag\n");
        tprint("1-9 + extra keys : set active tag\n");
        tprint("T                : set active tag (for tag id's >9)\n");
        tprint("s                : show image tags\n");
    }
    return;
}

sub show_image_tags {
	tprint("- \@image $im_i\n");
	my $n_tags_found = 0;
	for my $tag_i (sort {$a <=> $b} keys %images_for) {
		if (defined($images_for{$tag_i}->{$im_i})) {
			$n_tags_found++;
			tprint("- $tags{$tag_i}\n");
		}
	}
	if ($n_tags_found == 0) {
		tprint("- no tags yet\n");
	}
    tprint(">");
    return;
}


# (log output functions)
#===============================================================================

#===============================================================================
# miscellanea

sub compare_arrays { 
    my ($first, $second) = @_;
    return 0 unless @$first == @$second;
    for (my $i = 0; $i < @$first; $i++) {
        return 0 if $first->[$i] ne $second->[$i];
    }
    return 1;
}

sub tprint {
    my $print_string = shift;
    $log->insert('end', $print_string);
    $log->see('end');
    return;
}

sub tcolumn_print {
    my ($entry_arr_ref, $data_arr_ref, $n_columns, $entry_width, $column_width) = @_; 
    my @entry_arr = @$entry_arr_ref;
    my @data_arr = @$data_arr_ref;
	my $n_lines = ceil(@data_arr / $n_columns); 
	for my $line_i (1..$n_lines) {
		for my $c (1..$n_columns) {
			my $i = $n_columns * ($line_i - 1) + $c - 1;
            my $text;
			if ($i < @entry_arr) {
				$text = sprintf("%-$entry_width" . "s: %-$column_width" . "s  ", $entry_arr[$i], $data_arr[$i]);
                tprint($text);
			}
			else {
                # empty entry
				$text = sprintf("%-$entry_width" . "s  %-$column_width" . "s  ", '', '');
                tprint($text);
			}
		}
		tprint("\n");
	}
    return;
}

sub max {
    return $_[0] > $_[1] ? $_[0] : $_[1];
}

sub nearest_image {
    # always operates on subset; this script doesn't bother passing globals...
    # to be safe I don't assume @subset is sorted
    my ($index_in) = @_;
    return (sort {abs($a - $index_in) <=> abs($b - $index_in)} @subset)[0];
}

sub start_clock {
    # stop it first
    if ($clock_on) {
        $clock->cancel if defined $clock;
    }
    $clock = $mw->repeat($delay, \&auto_forward_image);
    $clock_on = 1;
    return;
}

sub stop_clock {
    if ($clock_on) {
        $clock->cancel if defined $clock;
    }
    $clock_on = 0;
    return;
}

# (miscellanea)
#===============================================================================
