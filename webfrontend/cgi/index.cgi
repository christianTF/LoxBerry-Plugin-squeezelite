#!/usr/bin/perl

# This is a sample Script file
# It does not much:
#   * Loading configuration
#   * including header.htmlfooter.html
#   * and showing a message to the user.
# That's all.

use File::HomeDir;
use Config::Simple;
use warnings;
use strict;
no strict "refs"; # we need it for template system

my  $home = File::HomeDir->my_home;
my  $lang;
my  $installfolder;
my  $cfg;
our $helptext;
our $template_title;

# Read Settings
$cfg             = new Config::Simple("$home/config/system/general.cfg");
$installfolder   = $cfg->param("BASE.INSTALLFOLDER");
$lang            = $cfg->param("BASE.LANG");

# Title
$template_title = "Sample Plugin";

# Create help page
$helptext = "This is a sample short help text showed up in the right slider.";
$helptext = $helptext . "<br><br>HTML markup is <b>supported</b>.";
$helptext = $helptext . "<br><br>Maybe better to load this from a template file...";

print "Content-Type: text/html\n\n";

# Currently only german is supported - so overwrite user language settings:
$lang = "de";

# Load header and replace HTML Markup <!--$VARNAME--> with perl variable $VARNAME
open(F,"$installfolder/templates/system/$lang/header.html") || die "Missing template system/$lang/header.html";
  while (<F>) {
    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
    print $_;
  }
close(F);

print "<div role=\"main\" class=\"ui-content\">\n";
print "<div class=\"ui-body ui-body-a ui-corner-all loxberry-logo\">\n";
print "<div style=\"margin: 5%;\">\n";

print "<center>";
print "<br><br>This is the Sample Plugin. It just do nothing.<br><br><br>";
print "Goodbye.";
print "</center>";

print "</div>\n";
print "</div>\n";
print "</div>\n";

# Load footer and replace HTML Markup <!--$VARNAME--> with perl variable $VARNAME
open(F,"$installfolder/templates/system/$lang/footer.html") || die "Missing template system/$lang/header.html";
  while (<F>) {
    $_ =~ s/<!--\$(.*?)-->/${$1}/g;
    print $_;
  }
close(F);

exit;
