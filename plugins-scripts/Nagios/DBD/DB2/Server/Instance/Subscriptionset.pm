package DBD::DB2::Server::Instance::Subscriptionset;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance);

{
  my @subscriptionsets = ();
  my $initerrors = undef;
  my $sample = {
    headers => 'APPLY_QUAL SET_NAME LASTRUN LASTSUCCESS SYNCHTIME ENDTIME SOURCE_CONN_TIME',
    data => [
      'EI2MISQ1 EAI2MISS1 2007-05-21-08.25.00.000000 2007-05-21-08.24.01.484509 2007-05-21-08.23.12.809407 2007-05-21-07.26.07.000000 2007-05-21-08.24.01.610647 2007-05-21-08.24.01.544292',
    ],
  };

  sub add_subscriptionset {
    push(@subscriptionsets, shift);
  }

  sub return_subscriptionsets {
    return reverse
        sort { $a->{name} cmp $b->{name} } @subscriptionsets;
  }

  sub init_subscriptionsets {
    my %params = @_;
    # name = apply_qual / die eindeutige kennung des apply-programms, ...
    # name2 = set_name / der name der subskriptionsgruppe ...
    my $num_subscriptionsets = 0;
    if (($params{mode} =~ /server::instance::replication::subscriptionsets::listsubscriptionsets/) ||
        ($params{mode} =~ /server::instance::replication::subscriptionsets::subscriptionlatency/)) {
      my @subscriptionsetresult = $params{handle}->fetchall_array(q{
          SELECT
              apply_qual,
              set_name,
              current timestamp,
              lastrun,
              lastsuccess,
              synchtime,
              source_conn_time,
              endtime,
          FROM asn.ibmsnap_applytrail
      });
      #@subscriptionsetresult = map { [split /\s+/] } @{$sample->{data}};
      foreach (@subscriptionsetresult) {
        my ($apply_qual, $set_name, $now, $lastrun, $lastsuccess, $synchtime, $source_conn_time, $endtime) = @{$_};
        if ($params{regexp}) {
          next if $params{selectname} && $apply_qual !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $apply_qual;
        }
        next if $params{name2} && lc $params{name2} ne lc $set_name;
        my %thisparams = %params;
        $thisparams{apply_qual} = $apply_qual;
        $thisparams{set_name} = $set_name;
        $thisparams{now} = DBD::DB2::Server::return_first_server()->convert_db2_timestamp($now);
        $thisparams{lastrun} = DBD::DB2::Server::return_first_server()->convert_db2_timestamp($lastrun);
        $thisparams{lastsuccess} = DBD::DB2::Server::return_first_server()->convert_db2_timestamp($lastsuccess);
        $thisparams{synchtime} = DBD::DB2::Server::return_first_server()->convert_db2_timestamp($synchtime);
        $thisparams{source_conn_time} = DBD::DB2::Server::return_first_server()->convert_db2_timestamp($source_conn_time);
        $thisparams{endtime} = DBD::DB2::Server::return_first_server()->convert_db2_timestamp($endtime);
        my $subscriptionset = DBD::DB2::Server::Instance::Subscriptionset->new(
            %thisparams);
        add_subscriptionset($subscriptionset);
        $num_subscriptionsets++;
      }
      if (! $num_subscriptionsets) {
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
    name => $params{name},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
  };
  foreach my $k (qw(apply_qual set_name now lastrun lastsuccess synchtime source_conn_time endtime)) {
    $self->{$k} = $params{$k};
  }
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  $self->set_local_db_thresholds(%params);
  if (($params{mode} =~ /server::instance::replication::subscriptionsets::subscriptionlatency/)) {
    $self->{run_lag} = $self->{now} - $self->{lastrun};
    $self->{success_lag} = $self->{now} - $self->{lastsuccess};
    $self->{latency} = $self->{now} - $self->{synchtime};
    $self->{end_to_end_latency} = $self->{endtime} - $self->{lastrun} + ($self->{source_conn_time} - $self->{synchtime});
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::replication::subscriptionsets::subscriptionlatency/) {
     # last successful < last run
     # and last run in the near past
      $self->add_nagios(
          $self->check_thresholds($self->{end_to_end_latency}, 600, 1200),       
          sprintf "synchronous read percentage is %.2f%%", $self->{srp});
      $self->add_perfdata(sprintf "end_to_end_latency=%.2f%%;%s;%s",
          $self->{end_to_end_latency},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}


1;
