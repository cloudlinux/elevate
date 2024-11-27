package Elevate::Components::Grub2ControlTest;

=encoding utf-8

=head1 NAME

Elevate::Components::Grub2ControlTest

=head2 mark_cmdline

Add a random option to the grub cmdline

=head2 verify_cmdline

Verify that the option is present after a reboot and block if it is not

=cut

use cPstrict;

use Elevate::OS        ();
use Elevate::StageFile ();

use Log::Log4perl qw(:easy);

use parent qw{Elevate::Components::Base};

use constant GRUBBY_PATH  => '/usr/sbin/grubby';
use constant CMDLINE_PATH => '/proc/cmdline';

# In place of Unix::Sysexits:
use constant EX_UNAVAILABLE => 69;

sub _call_grubby ( $self, @args ) {

    my %opts = (
        should_capture_output => 0,
        should_hide_output    => 0,
        die_on_error          => 0,
    );

    if ( ref $args[0] eq 'HASH' ) {
        my %opt_args = %{ shift @args };
        foreach my $key ( keys %opt_args ) {
            $opts{$key} = $opt_args{$key};
        }
    }

    unshift @args, GRUBBY_PATH;

    return $opts{die_on_error} ? $self->ssystem_and_die(@args) : $self->ssystem( \%opts, @args );
}

sub _default_kernel ($self) {
    return $self->_call_grubby( { should_capture_output => 1, should_hide_output => 1 }, '--default-kernel' )->{'stdout'}->[0] // '';
}

sub _persistent_id {
    my $id = Elevate::StageFile::read_stage_file( 'bootloader_random_tag', '' );
    return $id if $id;

    $id = int( rand(100000) );
    Elevate::StageFile::update_stage_file( { 'bootloader_random_tag', $id } );
    return $id;
}

sub mark_cmdline ($self) {
    return unless -x GRUBBY_PATH;

    my $arg = "elevate-" . _persistent_id;
    INFO("Marking default boot entry with additional parameter \"$arg\".");

    my $kernel_path = $self->_default_kernel;
    $self->_call_grubby( { die_on_error => 1 }, "--update-kernel=$kernel_path", "--args=$arg" );

    return;
}

sub _remove_but_dont_stop_service ($self) {

    $self->cpev->service->disable();
    $self->ssystem( '/usr/bin/systemctl', 'daemon-reload' );

    return;
}

sub verify_cmdline ($self) {
    return unless -x GRUBBY_PATH;
    if ( $self->cpev->upgrade_distro_manually() ) {
        my $arg = "elevate-" . _persistent_id;
        INFO("Checking for \"$arg\" in booted kernel's command line...");

        my $kernel_cmdline = eval { File::Slurper::read_binary(CMDLINE_PATH) } // '';
        DEBUG( CMDLINE_PATH . " contains: $kernel_cmdline" );

        my $detected = scalar grep { $_ eq $arg } split( ' ', $kernel_cmdline );
        if ($detected) {
            INFO("Parameter detected; restoring entry to original state.");
        }
        else {
            ERROR("Parameter not detected. Attempt to upgrade is being aborted.");
        }

        my $kernel_path = $self->_default_kernel;
        my $result      = $self->_call_grubby( "--update-kernel=$kernel_path", "--remove-args=$arg" );
        WARN("Unable to restore original command line. This should not cause problems but is unusual.") if $result != 0;

        if ( !$detected ) {

            # Can't use _notify_error as in run_service_and_notify, because that
            # tells you to use --continue, which won't work here due to the
            # do_cleanup invocation:
            my $stage              = Elevate::Stages::get_stage();
            my $pretty_distro_name = Elevate::OS::upgrade_to_pretty_name();
            my $msg                = <<"EOS";
The elevation process failed during stage $stage.

Specifically, the script could not prove that the system has control over its
own boot process using the utilities the operating system provides.

For this reason, the elevation process has terminated before making any
irreversible changes.

You can check the error log by running:

    $0

Before you can run the elevation process, you must provide for the ability for
the system to manipulate its own boot process. Then you can start the elevation
process anew:

    $0 --start

EOS
            Elevate::Notify::send_notification( qq[Failed to update to $pretty_distro_name] => $msg );

            $self->cpev->do_cleanup(1);
            $self->_remove_but_dont_stop_service();

            exit EX_UNAVAILABLE;    ## no critic(Cpanel::NoExitsFromSubroutines)
        }
    }

    return;
}

1;
