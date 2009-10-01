package DBD::DB2::Server::Instance::Database::Lock;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance::Database);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @locks = ();
  my $initerrors = undef;

  sub add_lock {
    push(@locks, shift);
  }

  sub return_locks {
    return reverse 
        sort { $a->{name} cmp $b->{name} } @locks;
  }
  
  sub init_locks {
    my %params = @_;
    my $num_locks = 0;
    if (($params{mode} =~ /server::instance::database::lock::deadlocks/) ||
        ($params{mode} =~ /server::instance::database::lock::lockwaits/) ||
        ($params{mode} =~ /server::instance::database::lock::lockwaiting/)) {
      my %thisparams = %params;
      $thisparams{name} = "dummy";
      my $lock = DBD::DB2::Server::Instance::Database::Lock->new(
          %thisparams);
      add_lock($lock);
      $num_locks++;
    }
  }
}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    name => $params{name},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::database::lock::deadlocks/) {
    $self->{deadlocks} = $params{handle}->fetchrow_array(q{
      SELECT deadlocks FROM sysibmadm.snapdb
    });
    if (defined $self->{deadlocks}) {
      $self->valdiff(\%params, qw(deadlocks));
      $self->{deadlocks_per_s} = $self->{delta_deadlocks} / $self->{delta_timestamp};
    } else {
      $self->add_nagios_critical('unable to aquire deadlock information');
    }
  } elsif ($params{mode} =~ /server::instance::database::lock::lockwaits/) {
    $self->{lock_waits} = $params{handle}->fetchrow_array(q{
      SELECT lock_waits FROM sysibmadm.snapdb
    });
    if (defined $self->{lock_waits}) {
      $self->valdiff(\%params, qw(lock_waits));
      $self->{lock_waits_per_s} = $self->{delta_lock_waits} / $self->{delta_timestamp};
    } else {
      $self->add_nagios_critical('unable to aquire lock_waits information');
    }
  } elsif ($params{mode} =~ /server::instance::database::lock::lockwaiting/) {
    ($self->{elapsed_exec_time}, $self->{lock_wait_time}) = $params{handle}->fetchrow_array(q{
      SELECT
          DOUBLE(elapsed_exec_time_s + elapsed_exec_time_ms / 1000000),
          DOUBLE(lock_wait_time / 1000)
      FROM sysibmadm.snapdb
    });
    if (defined $self->{lock_wait_time}) {
      $self->valdiff(\%params, qw(elapsed_exec_time lock_wait_time));
      $self->{lock_wait_time_percent} = $self->{delta_lock_wait_time} ?
          $self->{delta_lock_wait_time} / $self->{delta_elapsed_exec_time} * 100 : 0;
    } else {
      $self->add_nagios_critical('unable to aquire lock_wait_time information');
    }
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::database::lock::deadlocks/) {
      $self->add_nagios(
          $self->check_thresholds($self->{deadlocks_per_s}, 0, 1),
              sprintf("%.6f deadlocs / sec", $self->{deadlocks_per_s}));
      $self->add_perfdata(sprintf "deadlocks_per_sec=%.6f;%s;%s",
          $self->{deadlocks_per_s},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::lock::lockwaits/) {
      $self->add_nagios(
          $self->check_thresholds($self->{lock_waits_per_s}, 10, 100),
              sprintf("%.6f lock waits / sec", $self->{lock_waits_per_s}));
      $self->add_perfdata(sprintf "lock_waits_per_sec=%.6f;%s;%s",
          $self->{lock_waits_per_s},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::lock::lockwaiting/) {
      $self->add_nagios(
          $self->check_thresholds($self->{lock_wait_time_percent}, 2, 5),
              sprintf("%.6f%% of the time was spent waiting for locks", $self->{lock_wait_time_percent}));
      $self->add_perfdata(sprintf "lock_percent_waiting=%.6f%%;%s;%s",
          $self->{lock_wait_time_percent},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}


