#!/usr/bin/perl

#
# Copyright (C) 2022-2024 Joelle Maslak
# All Rights Reserved - See License
#

use 5.30.0;
use warnings;
use strict;

use feature 'signatures';
use feature 'postderef';
no warnings "experimental::signatures";
no warnings "experimental::postderef";

use List::Util qw/sum/;
use Mojo::JSON qw/encode_json decode_json/;
use Mojo::UserAgent;
use Perl6::Slurp;

my @holddown;
my @statistics;

our %CONFIG;

sub init() {
    my $file;
    if ( -f 'bastion.json' ) {
        $file = slurp("bastion.json");
    } elsif ( -f '/etc/bastion.json' ) {
        $file = slurp("/etc/bastion.json");
    } else {
        die("Could not find config file.");
    }
    %CONFIG = decode_json($file)->%*;
    return;
}

MAIN: {
    info("Starting");
    init();

    my $addr = get_dhcp_lease();
    if ( defined($addr) ) {
        info("Current DHCP Lease: $addr");
    } else {
        info("No DHCP lease");
    }

    my $group = get_current_group();
    if ( defined($group) ) {
        info("Current group IP: $group");
    } else {
        info("No current group IP");
    }
    set_dns($addr) if defined($addr);

    while (1) {
        if ( defined($addr) and ( $addr ne ( $group // 'none' ) ) ) {
            info("Setting group IP to $addr");
            set_group($addr);
            info("Setting DNS IP to $addr");
            set_dns($addr);
            $group = get_current_group();
        }

        sleep( $CONFIG{delay} );

        my $oldaddr = $addr;
        $addr = get_dhcp_lease();
        if ( ( !defined($addr) ) and ( defined($oldaddr) ) ) {
            info("No current DHCP lease!");
        } elsif ( !defined($addr) ) {
            # Do nothing.
        } elsif ( ( $oldaddr // 'none' ) ne $addr ) {
            info("Lease changed: $addr");
        }
    }
}

sub get_url($rest) {
    return "https://" . $CONFIG{device}{hostname} . ":" . $CONFIG{device}{port} . "/$rest";
}

sub get_dhcp_lease() {
    my $request_data =
      encode_json { op => 'show',
        path => [ 'dhcp', 'client', 'leases', 'interface', $CONFIG{interface} ] };

    my $ua = Mojo::UserAgent->new();
    $ua->insecure(1);
    my $tx =
      $ua->post( get_url("show"), form => { data => $request_data, key => $CONFIG{device}{key} } );
    if ( $tx->error() ) {
        error( "Could not connect to endpoint to fetch DHCP lease" );
        return undef;
    }
    my $res = $tx->result();
    if ( $res->is_error() ) {
        critical( "ERROR! Could not retrieve DHCP info - " . $res->message );
    }

    my $json = $res->json();
    if ( !$json->{success} ) { critical("Could not retrieve DHCP info") }

    my (@lines) = split /\n/, $json->{data};
    foreach my $line (@lines) {
        if ( $line =~ m/^ip address : ([0-9\.]+)\s+\[Active\]$/ ) {
            return $1;
        } elsif ( $line =~ m/^IP address\s+([0-9\.]+)\s+\[Active\]$/ ) {
            return $1;
        }
    }
    return undef;
}

sub get_current_group() {
    my $request_data =
      encode_json { op => 'showConfig',
        path => [ 'firewall', 'group', 'address-group', $CONFIG{group} ] };

    my $ua = Mojo::UserAgent->new();
    $ua->insecure(1);
    my $tx = $ua->post( get_url("retrieve"),
        form => { data => $request_data, key => $CONFIG{device}{key} } );
    if ( $tx->error() ) {
        error( "Could not connect to endpoint to fetch group" );
        return undef;
    }
    my $res = $tx->result();
    if ( $res->is_error() ) {
        critical( "ERROR! Could not retrieve group info - " . $res->message );
    }

    my $json = $res->json();
    if ( !$json->{success} ) { critical("Could not retrieve group info") }

    if ( exists( $json->{data}{address} ) ) {
        return $json->{data}{address};
    } else {
        return undef;
    }
}

sub set_group( $group ) {
    my $data = [
        {
            op   => 'delete',
            path => [ 'firewall', 'group', 'address-group', $CONFIG{group} ],
        },
        {
            op   => 'set',
            path => [ 'firewall', 'group', 'address-group', $CONFIG{group}, 'address', $group ],
        }
    ];

    foreach my $num ( $CONFIG{destination_rules}->@* ) {
        push $data->@*,
          {
            op   => 'set',
            path => [ 'nat', 'destination', 'rule', $num, 'destination', 'address', $group ],
          };
    }
    
    my $request_data = encode_json $data;

    my $ua = Mojo::UserAgent->new();
    $ua->insecure(1);

    my $tx = $ua->post( get_url("configure"),
        form => { data => $request_data, key => $CONFIG{device}{key} } );
    if ( $tx->error() ) {
        error( "Could not connect to endpoint to set group" );
        return undef;
    }
    my $res = $tx->result();
    if ( $res->is_error() ) {
        critical( "ERROR! Could not set group IP - " . $res->message );
    }

    return;
}

sub set_dns($ip) {
    info("Updating DNS");
    my $keyname = $CONFIG{dnssec}{keyname};
    my $key = $CONFIG{dnssec}{key};
    open(my $pipe, '|-', "nsupdate");

    my $hostname = $CONFIG{dnssec}{hostname};
    say $pipe "server $CONFIG{dnssec}{server}";
    say $pipe "key $keyname $key";
    say $pipe "update delete $hostname IN A";
    say $pipe "update add $hostname 60 IN A $ip";
    say $pipe "send";

    close $pipe;
}

sub critical(@args) {
    error(@args);
    error("Exiting.");
    exit(1);
}

sub error(@args) {
    logit( 'E', @args );
    return;
}

sub info(@args) {
    logit( 'I', @args );
    return;
}

sub logit ( $level, @args ) {
    local $| = 1;
    say( scalar(localtime) . " [$level] " . join( '', @args ) );
    return;
}

