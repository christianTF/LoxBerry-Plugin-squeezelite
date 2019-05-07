#!/usr/bin/perl
#udpserver.pl
# Source: http://www.thegeekstuff.com/2010/07/perl-tcp-udp-socket-programming/

# Christian Fenzl, 2017
# This is not used for normal operation.
# It simulates a simple UDP receiver like Loxone Miniserver is.
# For debugging, send UDP packages to this server instead of the Miniserver and see the UDP communication.

use IO::Socket::INET;

# flush after every write
$| = 1;

my ($socket,$received_data);
my ($peeraddress,$peerport);

#  we call IO::Socket::INET->new() to create the UDP Socket and bound 
# to specific port number mentioned in LocalPort and there is no need to provide 
# LocalAddr explicitly as in TCPServer.
$socket = new IO::Socket::INET (
LocalPort => '9093',
Proto => 'udp'
) or die "ERROR in Socket Creation : $!\n";

print "\nListening on port 5000\n";

while(1)
{
# read operation on the socket
$socket->recv($recieved_data,10000);

#get the peerhost and peerport at which the recent data received.
$peer_address = $socket->peerhost();
$peer_port = $socket->peerport();
print "($peer_address , $peer_port) said :\n$recieved_data";

#send the data to the client at which the read/write operations done recently.
$data = "data from server\n";
print $socket "$data";

}

$socket->close();
