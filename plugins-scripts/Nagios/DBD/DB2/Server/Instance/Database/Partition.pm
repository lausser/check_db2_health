package DBD::DB2::Server::Instance::Database::Partition;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance::Database);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @partitions = ();
  my $initerrors = undef;

  sub add_partition {
    push(@partitions, shift);
  }

  sub return_partitions {
    return reverse 
        sort { $a->{name} cmp $b->{name} } @partitions;
  }
  
  sub init_partitions {
    my %params = @_;
    my $num_partitions = 0;
    if ($params{mode} =~ /server::instance::database::logutilization/) {
      my @partitionresult = $params{handle}->fetchall_array(q{
        SELECT 
          dbpartitionnum, total_log_used_kb, total_log_available_kb,
          total_log_used_top_kb
        FROM
          sysibmadm.log_utilization
      });
      foreach (@partitionresult) {
        my ($num, $total_log_used_kb, $total_log_available_kb,
            $total_log_used_top_kb) = @{$_};
        my %thisparams = %params;
        $thisparams{num} = $num;
        $thisparams{total_log_used} = $total_log_used_kb * 1024;
        $thisparams{total_log_available} = $total_log_available_kb * 1024;
        $thisparams{total_log_used_top} = $total_log_used_top_kb * 1024;
        my $partition = DBD::DB2::Server::Instance::Database::Partition->new(
            %thisparams);
        add_partition($partition);
        $num_partitions++;
      }
      if (! $num_partitions) {
        $initerrors = 1;
        return undef;
      }
    }
  }
}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    num => $params{num},
    total_log_used => $params{total_log_used},
    total_log_available => $params{total_log_available},
    total_log_used_top => $params{total_log_used_top},
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
  if ($params{mode} =~ /server::instance::database::logutilization/) {
    $self->{log_utilization_percent} = $self->{total_log_used} /
        ($self->{total_log_used} + $self->{total_log_available}) * 100;
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::database::logutilization/) {
      $self->add_nagios(
          $self->check_thresholds($self->{log_utilization_percent}, "80", "90"),
              sprintf("log utilization of partition %s is %.2f%%", 
              $self->{num}, $self->{log_utilization_percent}));
      $self->add_perfdata(sprintf "\'part_%s_log_util\'=%.2f%%;%s;%s",
          $self->{num},
          $self->{log_utilization_percent},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "\'part_%s_log_used\'=%.2fMB",
          lc $self->{num},
          $self->{total_log_used} / 1048576);
      $self->add_perfdata(sprintf "\'part_%s_log_avail\'=%.2fMB",
          lc $self->{num},
          $self->{total_log_available} / 1048576);
      $self->add_perfdata(sprintf "\'part_%s_log_used_top\'=%.2fMB",
          lc $self->{num},
          $self->{total_log_used_top} / 1048576);
    }
  }
}


