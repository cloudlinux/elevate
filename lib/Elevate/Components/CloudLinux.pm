package Elevate::Components::CloudLinux;

=encoding utf-8

=head1 NAME

Elevate::Components::CloudLinux

=head2 check

Ensure CL license is valid

=head2 pre_distro_upgrade

noop

=head2 post_distro_upgrade

noop

=cut

use cPstrict;

use parent qw{Elevate::Components::Base};

use Elevate::OS ();

use Log::Log4perl qw(:easy);

use constant CLDETECT => '/usr/bin/cldetect';

sub check ($self) {
    return $self->_check_cloudlinux_license();
}

sub _check_cloudlinux_license ($self) {
    return 0 unless Elevate::OS::should_check_cloudlinux_license();

    # cldetect --check-license is the CloudLinux license check that works
    # across CloudLinux's licensing schemes (CLN, no-auth/SWNG, and
    # contract-licensed servers). We intentionally do NOT
    # also require rhn_check here: rhn_check is a CLN-registration XML-RPC
    # round-trip that reads /etc/sysconfig/rhn/systemid, so it always fails
    # on servers not registered with CLN - even when they hold a valid
    # CloudLinux license by other means - which produced a false "license
    # not valid" block (CLOS-4690). Leapp's check_cl_license actor performs
    # the CLN-specific rhn_check where it is actually meaningful.
    my $out = $self->ssystem_capture_output( CLDETECT, '--check-license' );

    if ( $out->{status} != 0 || grep { $_ !~ m/^ok/i } @{ $out->{stdout} } ) {

        $self->components->abort_on_first_blocker(1);

        return $self->has_blocker(<<~'EOS');
        The CloudLinux license is reporting that it is not currently valid.  A
        valid CloudLinux license is required to ELevate from CloudLinux 7 to
        CloudLinux 8.
        EOS
    }

    return 0;
}

1;
