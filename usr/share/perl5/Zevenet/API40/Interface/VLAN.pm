#!/usr/bin/perl
###############################################################################
#
#    Zevenet Software License
#    This file is part of the Zevenet Load Balancer software package.
#
#    Copyright (C) 2014-today ZEVENET SL, Sevilla (Spain)
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

use strict;

my $eload;
if ( eval { require Zevenet::ELoad; } )
{
	$eload = 1;
}

#  POST /interfaces/vlan Create a new vlan network interface
sub new_vlan    # ( $json_obj )
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $json_obj = shift;

	require Zevenet::Net::Util;
	require Zevenet::Net::Validate;

	my $desc = "Add a vlan interface";

	# validate VLAN NAME
	my $nic_re      = &getValidFormat( 'nic_interface' );
	my $vlan_tag_re = &getValidFormat( 'vlan_tag' );

	# vlan_name = pather_name + . + vlan_tag
	# size < 16: size = pather_name.vlan_tag:virtual_name
	if ( length $json_obj->{ name } > 13 )
	{
		my $msg = "VLAN interface name has a maximum length of 13 characters";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	if ( $json_obj->{ name } !~ /^($nic_re)\.($vlan_tag_re)$/ )
	{
		my $msg = "Interface name is not valid";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	$json_obj->{ parent } = $1;
	$json_obj->{ tag }    = $2;

	# validate PARENT
	my $parent_exist = &ifexist( $json_obj->{ parent } );

	unless ( $parent_exist eq "true" || $parent_exist eq "created" )
	{
		my $msg = "The parent interface $json_obj->{ parent } doesn't exist";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# check that nic interface is no slave of a bonding
	my $is_slave;

	for my $if_ref ( &getInterfaceTypeList( 'nic' ) )
	{
		if ( $if_ref->{ name } eq $json_obj->{ parent } )
		{
			$is_slave = $if_ref->{ is_slave };
			last;
		}
	}

	if ( $is_slave eq 'true' )
	{
		my $msg = "It is not possible create a VLAN interface from a NIC slave.";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# validate VLAN TAG
	unless ( $json_obj->{ tag } >= 1 && $json_obj->{ tag } <= 4094 )
	{
		my $msg = "The VLAN tag must be in the range 1-4094, both included";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# validate IP
	unless ( defined $json_obj->{ ip }
			 && &getValidFormat( 'ip_addr', $json_obj->{ ip } ) )
	{
		my $msg = "Invalid IP address.";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	$json_obj->{ ip_v } = ipversion( $json_obj->{ ip } );

	# Check if interface already exists
	my $if_ref = &getInterfaceConfig( $json_obj->{ name } );

	if ( $if_ref )
	{
		my $msg = "VLAN network interface $json_obj->{ name } already exists.";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# Check netmask errors
	unless ( defined $json_obj->{ netmask }
			 && &getValidFormat( 'ip_mask', $json_obj->{ netmask } ) )
	{
		my $msg = "Invalid network mask.";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# check if network exists in other interface
	if ( $json_obj->{ ip } or $json_obj->{ netmask } )
	{
		my $if_used = &checkNetworkExists( $json_obj->{ ip }, $json_obj->{ netmask } );
		if ( $if_used )
		{
			my $msg = "The network already exists in the interface $if_used.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	# Check gateway errors
	if ( exists $json_obj->{ gateway } )
	{
		unless ( defined ( $json_obj->{ gateway } )
				 && &getValidFormat( 'ip_addr', $json_obj->{ gateway } ) )
		{
			my $msg = "Invalid gateway address.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	# setup parameters of vlan
	my $socket = IO::Socket::INET->new( Proto => 'udp' );

	$if_ref = {
				name    => $json_obj->{ name },
				dev     => $json_obj->{ parent },
				status  => "up",
				vlan    => $json_obj->{ tag },
				addr    => $json_obj->{ ip },
				mask    => $json_obj->{ netmask },
				gateway => $json_obj->{ gateway } // '',
				ip_v    => &ipversion( $json_obj->{ ip } ),
				mac     => $socket->if_hwaddr( $if_ref->{ dev } ),
	};

	$if_ref->{ net } =
	  &getAddressNetwork( $if_ref->{ addr }, $if_ref->{ mask }, $if_ref->{ ip_v } );

	# Make sure the address, mask and gateway belong to the same stack
	if ( $if_ref->{ addr } )
	{
		my $ip_v = &ipversion( $if_ref->{ addr } );
		my $gw_v = &ipversion( $if_ref->{ gateway } );

		my $mask_v =
		    ( $ip_v == 4 && &getValidFormat( 'IPv4_mask', $if_ref->{ mask } ) ) ? 4
		  : ( $ip_v == 6 && &getValidFormat( 'IPv6_mask', $if_ref->{ mask } ) ) ? 6
		  :                                                                       '';

		if ( $ip_v ne $mask_v
			 || ( $if_ref->{ gateway } && $ip_v ne $gw_v ) )
		{
			my $msg = "Invalid IP stack version match.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	if ( $if_ref->{ gateway } )
	{
		unless (
			 &getNetValidate( $if_ref->{ addr }, $if_ref->{ mask }, $if_ref->{ gateway } ) )
		{
			my $msg = "Gateway does not belong to the interface subnet.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	require Zevenet::Net::Core;
	require Zevenet::Net::Route;
	require Zevenet::Net::Interface;

	eval {
		&zenlog( "new_vlan: $if_ref->{name}", "info", "NETWORK" );
		die if &createIf( $if_ref );
		die if &addIp( $if_ref );
		&writeRoutes( $if_ref->{ name } );

		my $state = &upIf( $if_ref, 'writeconf' );

		if ( $state == 0 )
		{
			$if_ref->{ status } = "up";
			&applyRoutes( "local", $if_ref );
		}

		&setInterfaceConfig( $if_ref ) or die;
	};

	if ( $@ )
	{
		my $msg = "The $json_obj->{ name } vlan network interface can't be created";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	my $body = {
				 description => $desc,
				 params      => {
							 name    => $if_ref->{ name },
							 ip      => $if_ref->{ addr },
							 netmask => $if_ref->{ mask },
							 gateway => $if_ref->{ gateway },
							 mac     => $if_ref->{ mac },
				 },
	};

	&httpResponse( { code => 201, body => $body } );
}

sub delete_interface_vlan    # ( $vlan )
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $vlan = shift;

	my $desc = "Delete VLAN interface";
	my $ip_v = 4;

	require Zevenet::Net::Interface;

	my $if_ref = &getInterfaceConfig( $vlan, $ip_v );

	# validate VLAN interface
	if ( !$if_ref )
	{
		my $msg = "The VLAN interface $vlan doesn't exist.";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# check if some farm is using this ip
	require Zevenet::Farm::Base;
	my @farms = &getFarmListByVip( $if_ref->{ addr } );
	if ( @farms )
	{
		my $str = join ( ', ', @farms );
		my $msg = "This interface is being used as vip in the farm(s): $str.";
		return &httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	my @child = &getInterfaceChild( $vlan );
	if ( @child )
	{
		my $child_string = join ( ', ', @child );
		my $msg =
		  "Before removing $vlan interface, delete the virtual interfaces: $child_string.";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	require Zevenet::Net::Core;
	require Zevenet::Net::Route;

	eval {
		die if &delRoutes( "local", $if_ref );
		die if &downIf( $if_ref, 'writeconf' );
		die if &delIf( $if_ref );
	};

	if ( $@ )
	{
		my $msg = "The VLAN interface $vlan can't be deleted";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	my $message = "The VLAN interface $vlan has been deleted.";
	my $body = {
				 description => $desc,
				 success     => "true",
				 message     => $message,
	};

	&httpResponse( { code => 200, body => $body } );
}

sub get_vlan_list    # ()
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	require Zevenet::Net::Interface;

	my $desc        = "List VLAN interfaces";
	my $output_list = &get_vlan_list_struct();

	my $body = {
				 description => $desc,
				 interfaces  => $output_list,
	};

	&httpResponse( { code => 200, body => $body } );
}

sub get_vlan    # ()
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $vlan = shift;

	require Zevenet::Net::Interface;

	my $desc      = "Show VLAN interface $vlan";
	my $interface = &get_vlan_struct( $vlan );

	unless ( $interface )
	{
		my $msg = "VLAN interface not found.";
		&httpErrorResponse( code => 404, desc => $desc, msg => $msg );
	}

	my $body = {
				 description => $desc,
				 interface   => $interface,
	};

	&httpResponse( { code => 200, body => $body } );
}

sub actions_interface_vlan    # ( $json_obj, $vlan )
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $json_obj = shift;
	my $vlan     = shift;

	require Zevenet::Net::Interface;

	my $desc = "Action on vlan interface";
	my $ip_v = 4;

	# validate VLAN
	unless ( grep { $vlan eq $_->{ name } } &getInterfaceTypeList( 'vlan' ) )
	{
		my $msg = "VLAN interface not found";
		&httpErrorResponse( code => 404, desc => $desc, msg => $msg );
	}

	# reject not accepted parameters
	if ( grep { $_ ne 'action' } keys %$json_obj )
	{
		my $msg = "Only the parameter 'action' is accepted";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# validate action parameter
	if ( $json_obj->{ action } eq "up" )
	{
		require Zevenet::Net::Validate;
		require Zevenet::Net::Route;
		require Zevenet::Net::Core;

		my $if_ref = &getInterfaceConfig( $vlan, $ip_v );

		# Create vlan if required if it doesn't exist
		my $exists = &ifexist( $if_ref->{ name } );
		if ( $exists eq "false" )
		{
			&createIf( $if_ref );
		}

		# Delete routes in case that it is not a vini
		&delRoutes( "local", $if_ref );

		# Add IP
		&addIp( $if_ref );

		# Check the parent's status before up the interface
		my $parent_if_name   = &getParentInterfaceName( $if_ref->{ name } );
		my $parent_if_status = 'up';

		if ( $parent_if_name )
		{
			my $parent_if_ref = &getSystemInterface( $parent_if_name );
			$parent_if_status = &getInterfaceSystemStatus( $parent_if_ref );
		}

		# validate PARENT INTERFACE STATUS
		unless ( $parent_if_status eq 'up' )
		{
			my $msg =
			  "The interface $if_ref->{name} has a parent interface DOWN, check the interfaces status";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}

		my $state = &upIf( $if_ref, 'writeconf' );

		if ( !$state )
		{
			&applyRoutes( "local", $if_ref );

			# put all dependant interfaces up
			require Zevenet::Net::Util;
			&setIfacesUp( $if_ref->{ name }, "vini" );
		}
		else
		{
			my $msg = "The interface $if_ref->{ name } could not be set UP";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}
	elsif ( $json_obj->{ action } eq "down" )
	{
		require Zevenet::Net::Core;

		my $state = &downIf( { name => $vlan }, 'writeconf' );

		if ( $state )
		{
			my $msg = "The interface could not be set DOWN";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}
	else
	{
		my $msg = "Action accepted values are: up or down";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	my $body = {
				 description => $desc,
				 params      => { action => $json_obj->{ action } },
	};

	&httpResponse( { code => 200, body => $body } );
}

sub modify_interface_vlan    # ( $json_obj, $vlan )
{
	&zenlog( __FILE__ . ":" . __LINE__ . ":" . ( caller ( 0 ) )[3] . "( @_ )",
			 "debug", "PROFILING" );
	my $json_obj = shift;
	my $vlan     = shift;

	require Zevenet::Net::Interface;
	require Zevenet::Net::Core;
	require Zevenet::Net::Validate;
	require NetAddr::IP;

	my $desc   = "Modify VLAN interface";
	my $if_ref = &getInterfaceConfig( $vlan );
	my @farms;

	# Check interface errors
	unless ( $if_ref )
	{
		my $msg = "VLAN interface not found";
		&httpErrorResponse( code => 404, desc => $desc, msg => $msg );
	}

	unless (    exists $json_obj->{ ip }
			 || exists $json_obj->{ netmask }
			 || exists $json_obj->{ gateway } )
	{
		my $msg = "No parameter received to be configured";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	# Check address errors
	if ( exists $json_obj->{ ip } )
	{
		unless ( defined ( $json_obj->{ ip } )
				 && &getValidFormat( 'ip_addr', $json_obj->{ ip } ) )
		{
			my $msg = "Invalid IP address.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	if ( $json_obj->{ ip } )
	{
		# check if some farm is using this ip
		require Zevenet::Farm::Base;
		@farms = &getFarmListByVip( $if_ref->{ addr } );
		if ( @farms and $json_obj->{ force } ne 'true' )
		{
			my $str = join ( ', ', @farms );
			my $msg =
			  "The IP is being used as farm vip in the farm(s): $str. If you are sure, repeat with parameter 'force'. All farms using this interface will be restarted.";
			return &httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	# Check netmask errors
	if ( exists $json_obj->{ netmask } )
	{
		unless (    $json_obj->{ netmask }
				 && &getValidFormat( 'ip_mask', $json_obj->{ netmask } ) )
		{
			my $msg = "Invalid network mask.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	# Check gateway errors
	if ( exists $json_obj->{ gateway } )
	{
		unless (
				 defined ( $json_obj->{ gateway } )
				 && (    $json_obj->{ gateway } eq ""
					  || &getValidFormat( 'ip_addr', $json_obj->{ gateway } ) )
		  )
		{
			my $msg = "Invalid gateway address.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	my $new_if = {
				   addr    => $json_obj->{ ip }      // $if_ref->{ addr },
				   mask    => $json_obj->{ netmask } // $if_ref->{ mask },
				   gateway => $json_obj->{ gateway } // $if_ref->{ gateway },
	};

	# Make sure the address, mask and gateway belong to the same stack
	if ( $new_if->{ addr } )
	{
		my $ip_v = &ipversion( $new_if->{ addr } );
		my $gw_v = &ipversion( $new_if->{ gateway } );

		my $mask_v =
		    ( $ip_v == 4 && &getValidFormat( 'IPv4_mask', $new_if->{ mask } ) ) ? 4
		  : ( $ip_v == 6 && &getValidFormat( 'IPv6_mask', $new_if->{ mask } ) ) ? 6
		  :                                                                       '';

		if ( $ip_v ne $mask_v
			 || ( $new_if->{ gateway } && $ip_v ne $gw_v ) )
		{
			my $msg = "Invalid IP stack version match.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

# Do not modify gateway or netmask if exists a virtual interface using this interface
	if ( exists $json_obj->{ ip } or exists $json_obj->{ netmask } )
	{
		my @child = &getInterfaceChild( $vlan );
		my @wrong_conf;

		foreach my $child_name ( @child )
		{
			my $child_if = &getInterfaceConfig( $child_name );
			unless (
				  &getNetValidate( $child_if->{ addr }, $new_if->{ mask }, $new_if->{ addr } ) )
			{
				push @wrong_conf, $child_name;
			}
		}

		if ( @wrong_conf )
		{
			my $child_string = join ( ', ', @wrong_conf );
			my $msg =
			  "The virtual interface(s): '$child_string' will not be compatible with the new configuration.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	# check if network exists in other interface
	if ( $json_obj->{ ip } or $json_obj->{ netmask } )
	{
		my $if_used =
		  &checkNetworkExists( $new_if->{ addr }, $new_if->{ mask }, $vlan );
		if ( $if_used )
		{
			my $msg = "The network already exists in the interface $if_used.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	# check the gateway is in network
	if ( $new_if->{ gateway } )
	{
		unless (
			 &getNetValidate( $new_if->{ addr }, $new_if->{ mask }, $new_if->{ gateway } ) )
		{
			my $msg = "The gateway is not valid for the network.";
			&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
		}
	}

	# Delete old parameters
	if ( $if_ref )
	{
		require Zevenet::Net::Core;
		require Zevenet::Net::Route;

		# Delete old IP and Netmask from system to replace it
		&delIp( $$if_ref{ name }, $$if_ref{ addr }, $$if_ref{ mask } );

		# Remove routes if the interface has its own route table: nic and vlan
		&delRoutes( "local", $if_ref );
	}

	$if_ref->{ addr }    = $json_obj->{ ip }      if exists $json_obj->{ ip };
	$if_ref->{ mask }    = $json_obj->{ netmask } if exists $json_obj->{ netmask };
	$if_ref->{ gateway } = $json_obj->{ gateway } if exists $json_obj->{ gateway };
	$if_ref->{ ip_v } = &ipversion( $if_ref->{ addr } );
	$if_ref->{ net } =
	  &getAddressNetwork( $if_ref->{ addr }, $if_ref->{ mask }, $if_ref->{ ip_v } );

	unless ( $if_ref->{ addr } && $if_ref->{ mask } )
	{
		my $msg = "Cannot configure the interface without address or without netmask.";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	eval {
		# Add new IP, netmask and gateway
		die if &addIp( $if_ref );
		die if &writeRoutes( $if_ref->{ name } );

		my $state = &upIf( $if_ref, 'writeconf' );

		if ( $state == 0 )
		{
			$if_ref->{ status } = "up";
			die if &applyRoutes( "local", $if_ref );
		}

		&setInterfaceConfig( $if_ref ) or die;

		# if the GW is changed, change it in all appending virtual interfaces
		if ( exists $json_obj->{ gateway } )
		{
			foreach my $appending ( &getInterfaceChild( $vlan ) )
			{
				my $app_config = &getInterfaceConfig( $appending );
				$app_config->{ gateway } = $json_obj->{ gateway };
				&setInterfaceConfig( $app_config );
			}
		}

		# put all dependant interfaces up
		require Zevenet::Net::Util;
		&setIfacesUp( $vlan, "vini" );

		# change farm vip,
		if ( @farms )
		{
			require Zevenet::Farm::Config;
			&setAllFarmByVip( $json_obj->{ ip }, \@farms );
		}
	};

	if ( $@ )
	{
		my $msg = "Errors found trying to modify interface $vlan";
		&httpErrorResponse( code => 400, desc => $desc, msg => $msg );
	}

	my $body = {
				 description => $desc,
				 params      => $json_obj,
	};

	&httpResponse( { code => 200, body => $body } );
}

1;
