#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2025 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

use lib '/usr/local/cpanel/';

use Cpanel::OS ();

use Test::More;

is( Cpanel::OS->distro(), 'almalinux', 'System is AlmaLinux after upgrade.' );
is( Cpanel::OS->major(),  '9',         'Verson 9 of OS.' );

done_testing();
