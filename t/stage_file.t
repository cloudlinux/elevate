#!/usr/local/cpanel/3rdparty/bin/perl

# HARNESS-NO-STREAM

# cpanel - t/small/scripts-elevate_c7_stage_file.t Copyright 2021 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use cPstrict;

use Test2::V0;
use Test2::Tools::Explain;
use Test2::Plugin::NoWarnings;
use Test2::Tools::Exception;

use Test::MockModule qw/strict/;

use Test::Cpanel::Policy;

use Test::MockFile;

use FindBin;

require $FindBin::Bin.q[/../elevate-cpanel];

$INC{'scripts/ElevateC7.pm'} = '__TEST__';

my $mock_elevate = Test::MockModule->new('scripts::ElevateC7');

my $mock_stage_file = Test::MockFile->file( scripts::ElevateC7::ELEVATE_STAGE_FILE() );

is scripts::ElevateC7::read_stage_file(), {}, 'read_stage_file empty file';

ok scripts::ElevateC7::save_stage_file( { fruits => ['cherry'] } ), 'save_stage_file';
is scripts::ElevateC7::read_stage_file(), { fruits => ['cherry'] }, 'read_stage_file';

ok scripts::ElevateC7::update_stage_file( { veggies => ['carrots'] } ), 'update_stage_file';
is scripts::ElevateC7::read_stage_file(), { fruits => ['cherry'], veggies => ['carrots'] }, 'read_stage_file';

$mock_stage_file->contents('');
is scripts::ElevateC7::read_stage_file(), {}, 'read_stage_file empty file';

ok scripts::ElevateC7::update_stage_file( { ea4 => { profile => q[myprofile] } } ), 'update_stage_file: ea4 profile';
ok scripts::ElevateC7::update_stage_file( { ea4 => { enable  => 1 } } ),            'update_stage_file: ea4 enable';

is scripts::ElevateC7::read_stage_file(), { ea4 => { profile => q[myprofile], enable => 1 } }, 'read_stage_file merging hashes';

{
    note "bumping the stage";

    $mock_stage_file->contents('');

    is scripts::ElevateC7::get_stage(), 0, 'stage 0';
    ok scripts::ElevateC7::bump_stage(), 'bump_stage';

    is scripts::ElevateC7::get_stage(), 1, 'stage 1';
    ok scripts::ElevateC7::bump_stage(), 'bump_stage';

    is scripts::ElevateC7::get_stage(), 2, 'stage 2';
    ok scripts::ElevateC7::bump_stage(), 'bump_stage';

    ok scripts::ElevateC7::update_stage_file( { key => 'value' } ), 'update_stage_file: add an extra entry';

    is scripts::ElevateC7::get_stage(), 3, 'stage 3';
    is scripts::ElevateC7::read_stage_file(), { stage_number => 3, key => 'value' }, 'read_stage_file: stage is preserved';
}

done_testing;
