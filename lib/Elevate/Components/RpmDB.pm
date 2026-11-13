package Elevate::Components::RpmDB;

=encoding utf-8

=head1 NAME

Elevate::Components::RpmDB

=head2 check

noop

=head2 pre_distro_upgrade

1. Remove packages provided via rpm.versions
2. Remove obsolete packages

=head2 post_distro_upgrade

1. Make the repositories cPanel needs visible to dnf when its reposdir leaves out
   cPanel's repo_dir (see _expose_cpanel_repos_to_dnf)
2. Install EPEL repo
3. Ensure epel, powertools, and crb repos are enabled
4. Force Perl reinstall
5. Update all packages
6. Execute sysup

=cut

use cPstrict;

use Elevate::Constants ();
use Elevate::OS        ();
use Elevate::PkgMgr    ();

use Cwd            ();
use File::Basename ();
use Log::Log4perl  qw(:easy);

use Cpanel::EA4::Install ();
use Cpanel::OS           ();
use Cpanel::Pkgr         ();
use Cpanel::Yum::Vars    ();

use parent qw{Elevate::Components::Base};

use constant OBSOLETE_PACKAGES => (
    'compat-db',
    'gd-progs',
    'python-tools',
    'python2-dnf',
    'python2-libcomps',
    'tcp_wrappers-devel',
    'tkinter',
    'yum-plugin-universal-hooks',
    'eigid',
    'quickinstall',
    'unattended-upgrades',
);

sub pre_distro_upgrade ($self) {

    $self->run_once("_cleanup_rpms");

    return;
}

sub _cleanup_rpms ($self) {

    # potential to remove other things, but the goal here to remove cpanel packages provided by rpm.versions
    Elevate::PkgMgr::remove_cpanel_arch_pkgs();

    # These packages are not available on 8 variants and will be removed by
    # leapp if we do not remove them manually.  Not necessarily a bug per se,
    # but it is better if we go ahead and handle removing these packages before
    # starting leapp
    $self->_remove_obsolete_packages();

    return;
}

sub _remove_obsolete_packages ($self) {

    my @pkgs_to_remove = grep { Cpanel::Pkgr::is_installed($_) } OBSOLETE_PACKAGES();
    Elevate::PkgMgr::remove(@pkgs_to_remove);
    return;
}

sub post_distro_upgrade ($self) {

    $self->run_once("_sysup");

    return;
}

sub _sysup ($self) {
    Cpanel::Yum::Vars::install();
    Elevate::PkgMgr::clean_all();

    $self->_expose_cpanel_repos_to_dnf();

    if ( Elevate::OS::needs_epel() ) {
        my $epel_url = 'https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm';

        # no failures once already installed: no need to check for the
        # epel-release version
        unless ( Cpanel::Pkgr::is_installed('epel-release') ) {
            Elevate::PkgMgr::install_pkg_via_url($epel_url);
        }

        Elevate::PkgMgr::config_manager_enable('epel');
    }

    Elevate::PkgMgr::config_manager_enable('powertools') if Elevate::OS::needs_powertools();
    Elevate::PkgMgr::config_manager_enable('crb')        if Elevate::OS::needs_crb();

    # Break cpanel-perl (NOTE: This needs to be updated each time we update Perl)
    unlink('/usr/local/cpanel/3rdparty/perl/536/cpanel-lib/X/Tiny.pm');
    unlink('/usr/local/cpanel/3rdparty/perl/542/cpanel-lib/X/Tiny.pm');
    {
        local $ENV{'CPANEL_BASE_INSTALL'} = 1;    # Don't fix more than perl itself.
        $self->ssystem(qw{/usr/local/cpanel/scripts/fix-cpanel-perl});
    }
    Elevate::PkgMgr::update_allow_erasing( '--disablerepo', 'cpanel-plugins' );
    $self->ssystem_and_die(qw{/usr/local/cpanel/scripts/sysup});

    return;
}

=head2 _expose_cpanel_repos_to_dnf

cPanel writes its repository files to C<Cpanel::OS::repo_dir()>
(F</etc/yum.repos.d>), and sysup enables C<Cpanel::OS::package_repositories()> by
ID. A C<reposdir=> in dnf.conf that leaves that directory out hides both: on
CloudLinux 9, sysup then fails on "Unknown repo: 'crb'" and, past that, on
dnf-plugin-universal-hooks, which only cPanel's F<EA4.repo> carries there.

When that is the case, link each file in repo_dir that defines a repository
cPanel needs and dnf cannot see into the first existing reposdir (where
C<dnf config-manager --add-repo> would write). The links stay: sysup runs on
every update. A repository the configured reposdir already provides, and a
file name already taken there, are left alone.

=cut

sub _expose_cpanel_repos_to_dnf ($self) {
    return if Elevate::OS::is_apt_based();

    my $repo_dir  = Cpanel::OS::repo_dir();
    my @reposdirs = $self->_dnf_reposdirs();
    return if !@reposdirs || grep { $_ eq $repo_dir } @reposdirs;

    my ($target) = grep { -d $_ } @reposdirs;
    if ( !$target ) {
        WARN( "dnf reads repositories only from " . join( ', ', @reposdirs ) . ", and none of these exists" );
        return;
    }

    INFO("dnf reads repositories only from $target, not from $repo_dir, where cPanel keeps its own. Linking what cPanel needs and dnf cannot see.");

    # sysup would download EA4.repo itself and install from it in the same run
    Cpanel::EA4::Install::install_ea4_repo() if Cpanel::OS::ea4_install_bare_repo();

    my $vars = $self->_dnf_variables();

    my %file_for;
    foreach my $file ( sort glob("$repo_dir/*.repo") ) {
        $file_for{$_} //= $file for _repo_ids_in_file( $file, $vars );
    }

    my @needed = Cpanel::OS::package_repositories()->@*;
    push @needed, _repo_ids_in_file( Cpanel::OS::ea4_from_bare_repo_path(), $vars ) if Cpanel::OS::ea4_install_bare_repo();

    my %visible = map { $_ => 1 } Elevate::PkgMgr::repolist_all();
    my ( %seen, %linked );
    foreach my $id ( grep { !$visible{$_} && !$seen{$_}++ } @needed ) {
        my $file = $file_for{$id};
        if ( !$file ) {
            WARN("cPanel needs the repository '$id', which neither $target nor $repo_dir defines");
            next;
        }
        next if $linked{$file}++;

        my $link = "$target/" . File::Basename::basename($file);
        if ( -e $link || -l $link ) {
            WARN("Not linking $link for the repository '$id' cPanel needs: a file of that name already exists");
            next;
        }

        INFO("Linking $link to $file for the repository '$id' cPanel needs");
        symlink( $file, $link ) or WARN("Could not link $link to $file: $!");
    }

    return;
}

sub _dnf_reposdirs ($self) {
    my $out = $self->ssystem_hide_and_capture_output(qw{/usr/bin/dnf config-manager --dump});
    return if $out->{status};

    my ($line) = grep { m/^reposdir\s*=/ } @{ $out->{stdout} };
    return if !defined $line;

    $line =~ s/^reposdir\s*=\s*//;
    return map { s{(?<=.)/+$}{}r } grep { length } split( m/[\s,]+/, $line );
}

sub _dnf_variables ($self) {
    my $out = $self->ssystem_hide_and_capture_output(qw{/usr/bin/dnf config-manager --dump-variables});
    return {} if $out->{status};

    return { map { m/^(\w+)\s*=\s*(.*)$/ ? ( $1 => $2 ) : () } @{ $out->{stdout} } };
}

# The repository IDs a .repo file defines, with dnf variables substituted as dnf does
sub _repo_ids_in_file ( $file, $vars ) {
    open( my $fh, '<', $file ) or return;

    my @ids;
    while ( my $line = <$fh> ) {
        next unless $line =~ m/^\s*\[([^\]]+)\]/;
        my $id = $1;
        next if $id eq 'main';
        $id =~ s{(\$(?:\{(\w+)\}|(\w+)))}{ $vars->{ $2 // $3 } // $1 }ge;
        push @ids, $id;
    }
    close $fh;

    return @ids;
}

1;
