#!/usr/local/cpanel/3rdparty/bin/perl

#                                      Copyright 2026 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

package test::cpev::components;

use FindBin;

use Test2::V0;
use Test2::Tools::Explain;
use Test2::Plugin::NoWarnings;
use Test2::Tools::Exception;
use Test2::Tools::Mock;

use Test::MockModule qw/strict/;

use File::Temp ();

use lib $FindBin::Bin . "/lib";
use Test::Elevate;

use cPstrict;

# cPanel writes its repository files to Cpanel::OS::repo_dir() (/etc/yum.repos.d)
# and sysup enables Cpanel::OS::package_repositories() by ID. When dnf.conf sets a
# reposdir= that leaves that directory out (e.g. /etc/yum.repos.local.d), dnf sees
# neither: on CloudLinux 9 sysup failed with "Unknown repo: 'crb'" and, once crb
# existed, "Unable to find a match: dnf-plugin-universal-hooks" (only in EA4.repo).

my $comp = cpev->new->get_component('RpmDB');

my $mock_comp = Test::MockModule->new('Elevate::Components::RpmDB');
my $mock_os   = Test::MockModule->new('Cpanel::OS');
my $mock_ea4  = Test::MockModule->new('Cpanel::EA4::Install');
my $mock_pkgr = Test::MockModule->new('Elevate::PkgMgr');

my $EA4_REPO = <<'EOS';
[EA4-$os_name_prefix$releasever]
name=EA4 ( EasyApache 4 - $os_name_prefix$releasever )
mirrorlist=http://httpupdate.cpanel.net/ea4-$os_name_prefix$releasever-$basearch-mirrorlist
enabled=1
EOS

my $CRB_REPO = <<'EOS';
[crb]
name=AlmaLinux $almalinux_releasever - CRB
enabled=1

[crb-debuginfo]
name=AlmaLinux $almalinux_releasever - CRB - Debug
enabled=0
EOS

my $EPEL_REPO = <<'EOS';
[epel]
name=Extra Packages for Enterprise Linux $releasever - $basearch
enabled=1
EOS

my %DNF_VARS = ( releasever => '9', basearch => 'x86_64', os_name_prefix => 'c', almalinux_releasever => '9.8' );

sub write_file ( $path, $content ) {
    open( my $fh, '>', $path ) or die "Cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return;
}

# One server: cPanel's repo_dir with the files stock CloudLinux 9 and cPanel put there,
# and a separate custom reposdir. EA4.repo appears only once install_ea4_repo() runs,
# as on the real box, where sysup downloads it.
sub setup_server (%opts) {
    my $root     = File::Temp->newdir();
    my $repo_dir = "$root/yum.repos.d";
    my $custom   = "$root/yum.repos.local.d";
    mkdir $repo_dir or die;
    mkdir $custom   or die;

    write_file( "$repo_dir/almalinux-crb.repo", $CRB_REPO );
    write_file( "$repo_dir/epel.repo",          $EPEL_REPO );

    my @calls;
    my %os = (
        repo_dir                => $repo_dir,
        package_repositories    => [qw/epel crb/],
        ea4_install_bare_repo   => $opts{ea4_install_bare_repo} // 1,
        ea4_from_bare_repo_path => "$repo_dir/EA4.repo",
    );
    foreach my $name ( sort keys %os ) {

        # Cpanel::OS answers these through AUTOLOAD, so the first mock defines them
        my $how = Cpanel::OS->can($name) ? 'redefine' : 'define';
        $mock_os->$how( $name => $os{$name} );
    }
    $mock_ea4->redefine(
        install_ea4_repo => sub (%) {
            push @calls, 'install_ea4_repo';
            write_file( "$repo_dir/EA4.repo", $EA4_REPO );
            return 1;
        },
    );
    $mock_comp->redefine(
        _dnf_reposdirs => sub ($) { push @calls, '_dnf_reposdirs'; return $opts{reposdirs} ? $opts{reposdirs}->( $repo_dir, $custom ) : ($custom) },
        _dnf_variables => sub ($) { return {%DNF_VARS} },
    );
    $mock_pkgr->redefine(
        repolist_all => sub () { push @calls, 'repolist_all'; return @{ $opts{visible} // [qw/epel cloudlinux-ea4 cloudlinux-os/] } },
    );

    return { root => $root, repo_dir => $repo_dir, custom => $custom, calls => \@calls };
}

sub links_in ($dir) {
    opendir( my $dh, $dir ) or die;
    my %links = map { $_ => readlink("$dir/$_") } grep { -l "$dir/$_" } readdir $dh;
    return \%links;
}

{
    note 'reposdir includes cPanel repo_dir (every stock server): nothing to do';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server( reposdirs => sub ( $repo_dir, $custom ) { return ( $repo_dir, '/etc/yum/repos.d', '/etc/distro.repos.d' ) } );

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,              'Returns undef' );
    is( $s->{calls},                          ['_dnf_reposdirs'], 'Neither installs the EA4 repo nor lists repos' );
    is( links_in( $s->{custom} ),             {},                 'Links nothing' );
    no_messages_seen();
}

{
    note 'reposdir cannot be read: nothing to do';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server( reposdirs => sub { return () } );

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,              'Returns undef' );
    is( $s->{calls},                          ['_dnf_reposdirs'], 'Neither installs the EA4 repo nor lists repos' );
    is( links_in( $s->{custom} ),             {},                 'Links nothing' );
    no_messages_seen();
}

{
    note 'custom reposdir without crb or EA4 (CloudLinux 9): link the files that define them';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server();
    my ( $repo_dir, $custom ) = @{$s}{qw/repo_dir custom/};

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,                                                    'Returns undef' );
    is( $s->{calls},                          [ '_dnf_reposdirs', 'install_ea4_repo', 'repolist_all' ], 'Installs the EA4 repo before deciding what dnf is missing' );
    is(
        links_in($custom),
        {
            'almalinux-crb.repo' => "$repo_dir/almalinux-crb.repo",
            'EA4.repo'           => "$repo_dir/EA4.repo",
        },
        'Links the files defining crb and EA4-c9, and not epel.repo, whose epel dnf already sees'
    );

    message_seen( INFO => qr{^dnf reads repositories only from \Q$custom\E, not from \Q$repo_dir\E, where cPanel keeps its own} );
    message_seen( INFO => "Linking $custom/almalinux-crb.repo to $repo_dir/almalinux-crb.repo for the repository 'crb' cPanel needs" );
    message_seen( INFO => "Linking $custom/EA4.repo to $repo_dir/EA4.repo for the repository 'EA4-c9' cPanel needs" );
    no_messages_seen();
}

{
    note 'several custom reposdirs: link into the first that exists, as dnf config-manager --add-repo does';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server( reposdirs => sub ( $repo_dir, $custom ) { return ( "$custom.missing", $custom ) } );
    my ( $repo_dir, $custom ) = @{$s}{qw/repo_dir custom/};

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,                                'Returns undef' );
    is( [ sort keys links_in($custom)->%* ],  [ 'EA4.repo', 'almalinux-crb.repo' ], 'Links into the existing one' );

    message_seen( INFO => qr{^dnf reads repositories only from \Q$custom\E, not from } );
    message_seen( INFO => qr{^Linking \Q$custom\E/almalinux-crb.repo } );
    message_seen( INFO => qr{^Linking \Q$custom\E/EA4.repo } );
    no_messages_seen();
}

{
    note 'no custom reposdir exists: warn, link nothing';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s      = setup_server( reposdirs => sub ( $repo_dir, $custom ) { return ("$custom.missing") } );
    my $custom = $s->{custom};

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,              'Returns undef' );
    is( $s->{calls},                          ['_dnf_reposdirs'], 'Neither installs the EA4 repo nor lists repos' );

    message_seen( WARN => "dnf reads repositories only from $custom.missing, and none of these exists" );
    no_messages_seen();
}

{
    note 'custom reposdir that already provides crb and EA4-c9: nothing to link';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server( visible => [qw/epel crb EA4-c9 cloudlinux-ea4/] );

    is( $comp->_expose_cpanel_repos_to_dnf(), undef, 'Returns undef' );
    is( links_in( $s->{custom} ),             {},    'Links nothing' );

    message_seen( INFO => qr{^dnf reads repositories only from } );
    no_messages_seen();
}

{
    note 'a file of the same name already in the custom reposdir is left alone';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server();
    my ( $repo_dir, $custom ) = @{$s}{qw/repo_dir custom/};
    write_file( "$custom/almalinux-crb.repo", "[almalinux-crb-mirror]\nname=theirs\n" );

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,                                  'Returns undef' );
    is( links_in($custom),                    { 'EA4.repo' => "$repo_dir/EA4.repo" }, 'Links only EA4.repo' );
    ok( !-l "$custom/almalinux-crb.repo", 'Their almalinux-crb.repo is not replaced' );

    message_seen( INFO => qr{^dnf reads repositories only from } );
    message_seen( WARN => "Not linking $custom/almalinux-crb.repo for the repository 'crb' cPanel needs: a file of that name already exists" );
    message_seen( INFO => "Linking $custom/EA4.repo to $repo_dir/EA4.repo for the repository 'EA4-c9' cPanel needs" );
    no_messages_seen();
}

{
    note 'a needed repository defined nowhere is reported, the others still linked';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server();
    my ( $repo_dir, $custom ) = @{$s}{qw/repo_dir custom/};
    unlink "$repo_dir/almalinux-crb.repo" or die;

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,                                  'Returns undef' );
    is( links_in($custom),                    { 'EA4.repo' => "$repo_dir/EA4.repo" }, 'Links EA4.repo' );

    message_seen( INFO => qr{^dnf reads repositories only from } );
    message_seen( WARN => "cPanel needs the repository 'crb', which neither $custom nor $repo_dir defines" );
    message_seen( INFO => "Linking $custom/EA4.repo to $repo_dir/EA4.repo for the repository 'EA4-c9' cPanel needs" );
    no_messages_seen();
}

{
    note 'no EA4 bare repo on this OS (CloudLinux 8 style): only package_repositories count';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    my $s = setup_server( ea4_install_bare_repo => 0 );
    my ( $repo_dir, $custom ) = @{$s}{qw/repo_dir custom/};

    is( $comp->_expose_cpanel_repos_to_dnf(), undef,                                                      'Returns undef' );
    is( $s->{calls},                          [ '_dnf_reposdirs', 'repolist_all' ],                       'Does not install the EA4 repo' );
    is( links_in($custom),                    { 'almalinux-crb.repo' => "$repo_dir/almalinux-crb.repo" }, 'Links only the crb file' );

    message_seen( INFO => qr{^dnf reads repositories only from } );
    message_seen( INFO => "Linking $custom/almalinux-crb.repo to $repo_dir/almalinux-crb.repo for the repository 'crb' cPanel needs" );
    no_messages_seen();
}

{
    note 'Ubuntu: nothing to do';
    clear_messages_seen();
    set_os_to( 'ubuntu', 20 );

    my $s = setup_server();

    is( $comp->_expose_cpanel_repos_to_dnf(), undef, 'Returns undef' );
    is( $s->{calls},                          [],    'Does not ask dnf anything' );
    no_messages_seen();
}

{
    note '_dnf_reposdirs and _dnf_variables parse dnf config-manager output';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );
    $mock_comp->unmock(qw/_dnf_reposdirs _dnf_variables/);

    my @cmds;
    my %stdout = (
        '--dump' => [
            '=================================== main ===================================',
            'reposdir = /etc/yum.repos.d, /etc/yum/repos.d/, /etc/distro.repos.d',
            'skip_if_unavailable = 1',
        ],
        '--dump-variables' => [ 'arch = x86_64', 'os_name_prefix = c', 'releasever = 9' ],
    );
    my $mock_cpev = Test::MockModule->new('cpev');
    $mock_cpev->redefine(
        ssystem_hide_and_capture_output => sub ( $, @args ) {
            push @cmds, [@args];
            return { status => 0, stdout => $stdout{ $args[-1] }, stderr => [] };
        },
    );

    is( [ $comp->_dnf_reposdirs() ], [ '/etc/yum.repos.d', '/etc/yum/repos.d', '/etc/distro.repos.d' ],                                'reposdir list, trailing slash dropped' );
    is( $comp->_dnf_variables(),     { arch => 'x86_64', os_name_prefix => 'c', releasever => '9' },                                   'variables' );
    is( \@cmds,                      [ [qw{/usr/bin/dnf config-manager --dump}], [qw{/usr/bin/dnf config-manager --dump-variables}] ], 'Asks dnf' );

    $stdout{'--dump'} = ['reposdir = /etc/yum.repos.local.d'];
    is( [ $comp->_dnf_reposdirs() ], ['/etc/yum.repos.local.d'], 'A single custom reposdir' );

    $mock_cpev->redefine( ssystem_hide_and_capture_output => sub ( $, @ ) { return { status => 256, stdout => [], stderr => ['No such command: config-manager'] } } );
    is( [ $comp->_dnf_reposdirs() ], [], 'Nothing when dnf fails' );
    is( $comp->_dnf_variables(),     {}, 'No variables when dnf fails' );

    no_messages_seen();
}

{
    note '_sysup makes the repositories visible before it enables crb and runs sysup';
    clear_messages_seen();
    set_os_to( 'cloud', 8 );

    # A tripwire on the statement right after the new step stops _sysup there, so
    # nothing past it runs: _sysup goes on to delete files under /usr/local/cpanel
    # and to run a real 'dnf update', which a test must never reach, also when the
    # step is missing or moved.
    my @calls;
    $mock_comp->redefine( _expose_cpanel_repos_to_dnf => sub ($) { push @calls, 'expose'; return } );
    $mock_pkgr->redefine( clean_all                   => sub () { push @calls, 'clean_all' } );
    my $mock_vars = Test::MockModule->new('Cpanel::Yum::Vars');
    $mock_vars->redefine( install => sub () { push @calls, 'yum vars' } );
    my $mock_cl8 = Test::MockModule->new('Elevate::OS::CloudLinux8');
    $mock_cl8->redefine( needs_epel => sub ($) { push @calls, 'needs_epel'; die "tripwire\n" } );

    is( dies { $comp->_sysup() }, "tripwire\n",                                        'Stops at the tripwire' );
    is( \@calls,                  [ 'yum vars', 'clean_all', 'expose', 'needs_epel' ], 'After the dnf variables are installed, before any repo is enabled and before sysup' );
}

done_testing();
