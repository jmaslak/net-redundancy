#!/usr/bin/env perl

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

my @statistics;
my @holddown;

my %CONFIG;

sub init() {
    my $file;
    if ( -f 'net-redundancy.json' ) {
        $file = slurp("net-redundancy.json");
    } elsif ( -f '/etc/net-redundancy.json' ) {
        $file = slurp("/etc/net-redundancy.json");
    } else {
        die("Could not find config file.");
    }
    %CONFIG = decode_json($file)->%*;

    @statistics = ();
    for ( 1 .. ( scalar $CONFIG{gateway}->@* ) ) {
        push @statistics, [];
        for ( 1 .. ( $CONFIG{sampling}{history} ) ) {
            push $statistics[-1]->@*, 0;
        }
        push @holddown, 0;
    }
    return;
}

MAIN: {
    info("Starting");
    init();
    my $current = 0;

    my $gw = get_default();
    info( "Router currently using ", $CONFIG{gateway}[$gw]{address}, " as default gateway" );
    # tweet("Starting network monitoring and switching script");
    sleep(60);

    while (1) {
        do_pings();
        my $best    = pick_gateway();
        my $best_ip = $CONFIG{gateway}[$best]{address};

        if ( $best ne $gw ) {
            # Apply penalty
            $holddown[$gw] = time;

            # Swap gateway
            $gw = $best;

            my (@sums) = get_sums();
            my $sumline = join( " ", @sums );

            info( "Setting gateway to ", $best_ip, " - Stats: [", $sumline, "]" );
            set_gateway($best_ip);

            if ( exists( $CONFIG{gateway}[$best]{tweet} ) ) {
                tweet( $CONFIG{gateway}[$best]{tweet} );
            }
        }

        sleep( $CONFIG{sampling}{delay} );
    }
}

sub get_url($rest) {
    return "https://" . $CONFIG{device}{hostname} . ":" . $CONFIG{device}{port} . "/$rest";
}

sub get_default() {
    my $request_data =
      encode_json { op => 'showConfig', path => [ 'protocols', 'static', 'route', '0.0.0.0/0' ] };

    my $ua = Mojo::UserAgent->new();
    $ua->insecure(1);
    my $tx = $ua->post( get_url("retrieve"),
        form => { data => $request_data, key => $CONFIG{device}{key} } );
    my $res = $tx->result();
    if ( $res->is_error() ) {
        critical( "ERROR! Could not retrieve gateway - " . $res->message );
    }

    my $json = $res->json();
    if ( !$json->{success} ) { critical("Could not retrieve gateway") }

    my (@nexthops) = keys $json->{data}{'next-hop'}->%*;
    if ( scalar(@nexthops) != 1 ) {
        critical("Wrong number of next hops present!");
    }

    my $current_gw;
    for ( my $i = 0; $i < scalar( $CONFIG{gateway}->@* ); $i++ ) {
        if ( $nexthops[0] eq $CONFIG{gateway}[$i]{address} ) {
            $current_gw = $i;
        }
    }

    if ( !defined($current_gw) ) {
        critical( "Router has an unknown default gateway: " . $nexthops[0] );
    }

    return $current_gw;
}

sub set_gateway ( $gateway ) {
    my $request_data = my $request_data_set = encode_json [
        {
            op   => 'delete',
            path => [ 'protocols', 'static', 'route', '0.0.0.0/0' ]
        },
        {
            op   => 'set',
            path => [ 'protocols', 'static', 'route', '0.0.0.0/0', 'next-hop', $gateway ]
        }
    ];

    my $ua = Mojo::UserAgent->new();
    $ua->insecure(1);
    $ua->inactivity_timeout(300);

    my $tx = $ua->post( get_url("configure"),
        form => { data => $request_data, key => $CONFIG{device}{key} } );
    my $res = $tx->result();
    if ( $res->is_error() ) {
        critical( "ERROR! Could not set gateway - " . $res->message );
    }

    return;
}

sub do_pings() {
    for my $index ( 0 .. ( scalar( $CONFIG{gateway}->@* ) - 1 ) ) {
        shift $statistics[$index]->@*;
        push $statistics[$index]->@*, 0;

        my $success;
        my $best = 0;
        for my $target ( $CONFIG{gateway}[$index]{targets}->@* ) {
            $success = 0;
            for ( 1 .. $CONFIG{sampling}{pings} ) {
                if (!system("ping -c 1 -q -W 1 -n $target >/dev/null")) {
                    $success++;
                }
            }
            if ($success > $best) { $best = $success }
        }
        $statistics[$index][-1] = $best;
    }

    return;
}

sub pick_gateway() {
    my (@sums) = get_sums();

    # Apply holddowns
    for ( my $i = 0; $i < scalar(@sums); $i++ ) {
        if ( $holddown[$i] + $CONFIG{holddown}{delay} > time ) {
            # We are still in holddown
            if ( $sums[$i] >= ( $CONFIG{holddown}{penalty} + $CONFIG{holddown}{minimum} ) ) {
                # We can penalize
                $sums[$i] -= $CONFIG{holddown}{penalty};
            } elsif ( $sums[$i] > $CONFIG{holddown}{minimum} ) {
                # Clause for cases where sums > minimum but
                # subtracting penality would make it less - in
                # this case, we set to minium.
                $sums[$i] = $CONFIG{holddown}{minimum};
            }    # We do not need to handle the case where the sum is less than minimum
        }
    }

    my $best = 0;

    for my $i ( 1 .. ( scalar(@sums) - 1 ) ) {
        if ( ( $sums[$best] + $CONFIG{sampling}{delta} ) <= $sums[$i] ) {
            $best = $i;
        }
    }

    return $best;
}

sub get_sums() {
    my @sums = map { sum $_->@* } @statistics;
    return @sums;
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

sub tweet($msg) {
    $msg = scalar(localtime) . " $msg";
    # system( "(echo 't $msg' ; echo q) | " . $CONFIG{rainbowstream} . ' >/dev/null' );
    system( $CONFIG{toot} . " post -v unlisted '$msg' >/dev/null" );
    return;
}

