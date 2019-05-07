#!/usr/bin/perl

package Hello;

use strict;
use warnings;
use WWW::Curl::Easy;
use WWW::Curl::Multi;
 
my %easy;
my $curl = WWW::Curl::Easy->new;
my $curl_id = '13'; # This should be a handle unique id.
$easy{$curl_id} = $curl;
my $active_handles = 0;
 
$curl->setopt(CURLOPT_PRIVATE,$curl_id);
$curl->setopt(CURLOPT_URL,"http://localhost/plugins/text2speech/index.php");
 
my $curlm = WWW::Curl::Multi->new;
 
# Add some easy handles
$curlm->add_handle($curl);
$active_handles++;
 
while ($active_handles) {
        my $active_transfers = $curlm->perform;
        if ($active_transfers != $active_handles) {
                print "Active: $active_transfers\n";
		while (my ($id,$return_value) = $curlm->info_read) {
                        print "id $id return_value $return_value\n";
			if ($id) {
                                $active_handles--;
                                my $actual_easy_handle = $easy{$id};
                                # do the usual result/error checking routine here
                                
				print "Response: " . $actual_easy_handle->getinfo("CURLINFO_RESPONSE_CODE") . "\n";

				# letting the curl handle get garbage collected, or we leak memory.
                                delete $easy{$id};
                        }
                }
        }
}


1;

