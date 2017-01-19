use strict;
package Basics;
use base 'Exporter';
our @EXPORT = (
	'is_true',
	'is_false',
	'trim',
);


####################################################
# is_true - tries to detect if a string says 'True'
####################################################
sub is_true
{ 
	my ($text) = @_;
	$text =~ s/^\s+|\s+$//g;
	$text = lc $text;
	if ($text eq "true") { return 1;}
	if ($text eq "yes") { return 1;}
	if ($text eq "on") { return 1;}
	if ($text eq "enabled") { return 1;}
	if ($text eq "1") { return 1;}
	return 0;
}

####################################################
# is_true - tries to detect if a string says 'True'
####################################################
sub is_false
{ 
	my ($text) = @_;
	$text =~ s/^\s+|\s+$//g;
	$text = lc $text;
	if ($text eq "false") { return 1;}
	if ($text eq "no") { return 1;}
	if ($text eq "off") { return 1;}
	if ($text eq "disabled") { return 1;}
	if ($text eq "0") { return 1;}
	return 0;
}

#####################################################
# Strings trimmen
#####################################################

sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };


#####################################################
# Finally 1; ########################################
#####################################################
1;
