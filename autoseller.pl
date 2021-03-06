#!/usr/bin/perl

use Getopt::Long; # command-line options
use POSIX qw( pow );
use warnings;
use strict;

# dependencies
require Log::Log4perl; # logging
use Try::Tiny; # error handling

# our modules
use Autosell::API::CoinEx; # CoinEx API
use Autosell::Config qw( load ); # our config loader

# init
my $config = undef;
my $configFile = undef;

Log::Log4perl->init( "log.conf" );
my $log = Log::Log4perl->get_logger( "autoseller" );
$log->info;
$log->info( "Autoseller started." );

# catch interrupt
$SIG{INT} = sub { $log->info( "sigint '$!' received, quitting." ); exit 0; };

GetOptions( "usage|help|h|u"               => \&usage ,
            "config|file|configfile|cfg:s" => \$configFile );

# init and load config
$config = Autosell::Config->new( $configFile );
$config->load();

# load exchanges
my $exchanges = []; # array of exchanges(each a hash)
for my $exchange ( keys % { $config->{ apikeys } } )
{
    &loadExchange( $exchange );
}

# error check, shouldn't ever happen as config checks for this
$log->error_die( "No exchanges configured!" ) unless ( @$exchanges );

# poll loop
while ( 1 )
{
    foreach my $exchange ( @$exchanges )
    {
        $log->trace( "Querying balances on $exchange->{ name }..." );
        try
        {
            my $balances = $exchange->{ exchange }->balances(
                keys % { $exchange->{ currencies } } );
                    
            # request delay
            $log->trace( "Sleeping for $config->{ request }s.");
            sleep $config->{ request };
            
            # try to trade balances
            TRADE: foreach my $currencyID ( keys % { $balances } )
            {
                # adjust to real balance(/10^8)
                my $realBal = $balances->{ $currencyID } / pow( 10 , 8 );
                
                # ignore currencies we don't have a market for
                unless ( $exchange->{ markets }->{ $currencyID } )
                {
                    $log->trace(
                        sprintf( "No trade pair for %s, ignoring %.8f %s." ,
                            $exchange->{ currencies }->{ $currencyID } ,
                            $realBal ,
                            $exchange->{ currencies }->{ $currencyID } ) );
                    next TRADE;
                }
                
                if ( $exchange->{ currencies }->{ $currencyID } eq $config->{ target } )
                {
                    $log->trace(
                        sprintf( "Ignoring target currency. Bal: %.8f %s" ,
                            $realBal ,
                            $exchange->{ currencies }->{ $currencyID } ) );
                }
                elsif ( $realBal >=
                    ( $config->{ coinmins }->{ $exchange->{ currencies }->{ $currencyID } } || 0 ) )
                {
                    $log->trace(
                        sprintf( "Attempting to sell %.8f %s" ,
                            $realBal ,
                            $exchange->{ currencies }->{ $currencyID } ) );
                    
                    # try to sell
                    try
                    {
                        my $order = $exchange->{ exchange }->sellOrder(
                            $exchange->{ markets }->{ $currencyID } ,
                            $balances->{ $currencyID } ,
                            $config->{ strategy } );
                        
                        $log->info(
                            sprintf( "Created sell order ID %d for %.8f %s @ %.8f %s on %s!" ,
                                $order->{ id } , # order ID
                                $realBal , # coin balance
                                $exchange->{ currencies }->{ $currencyID } , # currency name
                                $order->{ rate } / pow( 10 , 8 ) , # price/rate of order
                                $config->{ target } , # target currency name
                                $exchange->{ name } ) ); # exchange name
                    }
                    catch
                    {
                        $log->error(
                            sprintf( "Unable to create sell order for %.8f %s on %s." ,
                                $realBal , # formatted balance
                                $exchange->{ currencies }->{ $currencyID } , # currency name
                                $exchange->{ name } ) ); # exchange name
                    };
                    
                    # request delay
                    $log->trace( "Sleeping for $config->{ request }s.");
                    sleep $config->{ request };
                }
                else
                {
                    $log->trace( sprintf( "Ignoring balance of %.8f %s, below min amount." ,
                        $realBal ,
                        $exchange->{ currencies }->{ $currencyID } ) );
                }
            }
        }
        catch
        {
            # sleep if we errored out on a request
            $log->trace( "Sleeping for $config->{ request }s.");
            sleep $config->{ request };
        };
    }
    
    # sleep until it's time for next poll
    $log->trace( "Sleeping for $config->{ poll }s.");
    sleep $config->{ poll };
}

####################################################################################################
# Load exchange from config
#
# Params:
#   exchange: name of exchange we're loading
####################################################################################################
sub loadExchange
{
    my $exchange = shift || '';

    $log->debug( "Loading $exchange..." );

    my $exchangeref = { name => $exchange };
    
    # load coinex API
    if ( $exchange =~ /^(coinex)/i )
    {
        # load exchange
        $exchangeref->{ exchange } =
            Autosell::API::CoinEx->new(
                $exchange ,
                $config->{ apikeys }->{ $exchange }->{ key } ,
                $config->{ apikeys }->{ $exchange }->{ secret } );
    }
    # TODO other exchanges
    else
    {
        $log->error( "Unsupported exchange: $exchange" );
        return;
    }
    
    # attempt to grab currencies from exchange
    $exchangeref->{ currencies } =
        $exchangeref->{ exchange }->currencies( @ { $config->{ excludes } } );
    
    # attempt to grab markets exchange
    $exchangeref->{ markets } =
        $exchangeref->{ exchange }->markets(
            $config->{ target } , $exchangeref->{ currencies } );
    
    # log what we've found
    $log->debug( "Found " . keys( % { $exchangeref->{ currencies } } ) .
        " relevant currencies and " .
        keys( % { $exchangeref->{ markets } } ) . " markets for them." );
    
    push(@$exchanges, $exchangeref );
    
    $log->info( "Monitoring $exchange." );
    
    # sleep for request delay so we don't get a "too many requests" error
    $log->trace( "Sleeping for $config->{ request }s.");
    sleep $config->{ request };
}

####################################################################################################
# usage
# 
# Print script usage
####################################################################################################
sub usage
{
    print "\n" .
          "$0\n" .
          "Autosell coins on an exchange\n" .
          "\n" .
          "Options:\n" .
          "    -usage: Prints usage\n" .
          "    -config=<filename>: Config file(optional)\n" .
          "\n" .
          "Usage:\n" .
          "    $0\n" .
          "    $0 -usage\n" .
          "    $0 -config=<filename>\n" .
          "\n";
    
    # done
    exit 0;
}
