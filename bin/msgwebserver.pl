#!/usr/bin/perl
use Mojolicious::Lite;
use LoxBerry::Log;
use LoxBerry::System;
use LoxBerry::JSON;
#use Data::Dumper;
use Getopt::Long qw(GetOptions);
#use HTML::Entities;
#use LWP::UserAgent;
use URI::Escape;
use strict;
use warnings;

# Config parameters
my $version = "1.0.6";
my $log;
my $datafile = "/dev/shm/lms2udp_data.json";
my $playerstates;
my $cfg;
my $debug;


# Termination handling
$SIG{INT} = sub { 
	if($log) {
		$log->default();
		LOGOK("MSGWEBSERVER interrupted by Ctrl-C"); 
		LOGTITLE("MSGWEBSERVER interrupted by Ctrl-C"); 
		LOGEND("msgwebserver.pl ended");
	}
	exit 1;
};

$SIG{TERM} = sub { 
	if($log) {
		$log->default();
		LOGOK("MSGWEBSERVER requested to stop"); 
		LOGTITLE("MSGWEBSERVER requested to stop"); 
		LOGEND;
	}
	exit 1;	
};

# Create a logging object
$log = LoxBerry::Log->new (
        name => 'msgwebserver',
	addtime => 1,
);

# Commandline options
my $verbose = '';

GetOptions ('verbose' => \$verbose,
            'quiet'   => sub { $verbose = 0 });

# Due to a bug in the Logging routine, set the loglevel fix to 3
if ($verbose) {
        $log->stdout(1);
        $log->loglevel(7);
	$debug = 1;
}

LOGSTART("Daemon MSGWERVER started");
LOGDEB "This is $0 Version $version";

# Creating pid
my $pidfile = "/run/shm/msgwebserver.$$";
open(my $fh, '>', $pidfile);
print $fh "$$";
close $fh;
#LOGDEB "My PID is: $$";

&readstates();
foreach my $players (keys %{$playerstates}) {
	LOGDEB "$players";
}
exit;





post '/zone/:zone/:command' => sub {
  my $c = shift;
  my $zone = $c->stash('zone');
  my $command = $c->stash('command');
  print "----------------------------------------------\n" if $debug;
  print "The body is:\n" if $debug;
  print Dumper $c->req->body . "\n" if $debug;
  print "The zone is: $zone\n" if $debug;
  print "The command is: $command\n" if $debug;
  print "----------------------------------------------\n" if $debug;
};

get '/zone/:zone/state' => sub {
  my $c = shift;
  my $zone = $c->stash('zone');
  print "----------------------------------------------\n" if $debug;
  print "The body is:\n" if $debug;
  print Dumper $c->req->body . "\n" if $debug;
  print "The zone is: $zone\n" if $debug;
  print "----------------------------------------------\n" if $debug;
};

####################################################################
# Subs
# ##################################################################

sub readstates {

	my $jsonobj = LoxBerry::JSON->new();
	$playerstates = $jsonobj->open(filename => $datafile, readonly => 1);
	foreach my $players (keys %{$playerstates}) {
		LOGDEB "$players";
	}
	print "Test";
	return (1);

}

#app->start;
app->start('daemon', '-l', 'http://*:8091');
