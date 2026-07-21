#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2024 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

package test::cpev::components;

use FindBin;

use Test2::V0;
use Test2::Tools::Explain;
use Test2::Plugin::NoWarnings;
use Test2::Tools::Exception;

use Test::MockFile 0.032;
use Test::MockModule qw/strict/;

use lib $FindBin::Bin . "/lib";
use Test::Elevate;

use cPstrict;

my $cpev_mock = Test::MockModule->new('cpev');
my $cl_mock   = Test::MockModule->new('Elevate::Components::CloudLinux');

my $cpev = cpev->new;
my $cl   = $cpev->get_blocker('CloudLinux');

{
    note 'testing _check_cloudlinux_license';

    my $cpev_mock = Test::MockModule->new('cpev');

    my $system_status         = 0;
    my $capture_output_status = 0;
    my @cmds;
    my @stdout;
    $cpev_mock->redefine(
        ssystem => sub ( $, @args ) {
            push @cmds, [@args];
            return $system_status;
        },
        ssystem_capture_output => sub ( $, @args ) {
            push @cmds, [@args];
            return { status => $capture_output_status, stdout => \@stdout, stderr => [] };
        },
    );

    my %os_hash = (
        cent   => [7],
        ubuntu => [20],
        alma   => [8],
    );
    foreach my $os ( sort keys %os_hash ) {
        foreach my $version ( @{ $os_hash{$os} } ) {
            set_os_to( $os, $version );

            is $cl->_check_cloudlinux_license(), 0, "The blocker check is skipped and returns 0 when the OS is $os $version";
        }
    }

    foreach my $version ( 7, 8 ) {
        set_os_to( 'cloud', 8 );

        # CLOS-4690 regression: rhn_check failing must NOT block the upgrade
        # as long as cldetect reports a valid license. rhn_check is a
        # CLN-registration round-trip that always fails on servers not
        # registered with CLN (no-auth / contract-licensed),
        # so it is no longer consulted here.
        $system_status         = 1;        # rhn_check would fail IF it were called
        $capture_output_status = 0;
        @stdout                = ('ok');

        # Before the fix this raised an abort blocker, so catch it: a regression
        # should fail here by name rather than end the test file.
        my $result;
        ok(
            lives { $result = $cl->_check_cloudlinux_license() },
            'A failing rhn_check does not raise a blocker when cldetect reports OK (CLOS-4690)'
        ) or note $@;
        is $result, 0, 'No blocker when cldetect reports OK, even though rhn_check would fail (CLOS-4690)';

        is(
            \@cmds,
            [ [ '/usr/bin/cldetect', '--check-license' ] ],
            'Only cldetect is consulted; rhn_check is no longer called'
        );

        no_messages_seen();
        @cmds = ();

        # cldetect exits non-zero -> blocker
        $capture_output_status = 1;
        @stdout                = ();

        my $blocker = dies { $cl->_check_cloudlinux_license() };

        is ref $blocker, 'cpev::Blocker', 'A blocker object is returned when cldetect exits non-zero';
        check_blocker_content($blocker);
        @cmds = ();

        # cldetect prints a non-ok line -> blocker
        $capture_output_status = 0;
        @stdout                = ('CL license is not ok');

        $blocker = dies { $cl->_check_cloudlinux_license() };

        check_blocker_content($blocker);
        @cmds = ();

        # cldetect reports OK -> no blocker
        @stdout = ('ok');

        is $cl->_check_cloudlinux_license(), 0, 'No blockers are found when CL has a valid license';

        no_messages_seen();

        @cmds = ();
    }
}

sub check_blocker_content ($blocker) {

    like(
        $blocker,
        {
            id  => 'Elevate::Components::CloudLinux::_check_cloudlinux_license',
            msg => qr/^The CloudLinux license is reporting that it is not currently valid/,
        },
        'The expected blocker is returned'
    );

    return;
}

done_testing();
