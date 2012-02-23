package DBD::DB2::Server::Instance::Subscriptionset;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance);

{
  my @subscriptionsets = ();
  my $initerrors = undef;
  my $sample = {
    headers => 'APPLY_QUAL SET_NAME now LASTRUN LASTSUCCESS SYNCHTIME ENDTIME SOURCE_CONN_TIME',
    data => [
      'EI2MISQ1 EAI2MISS1 2007-05-21-08.25.00.000000 2007-05-21-08.24.01.484509 2007-05-21-08.23.12.809407 2007-05-21-07.26.07.000000 2007-05-21-08.24.01.610647 2007-05-21-08.24.01.544292',
    ],
  };

  sub add_subscriptionset {
    push(@subscriptionsets, shift);
  }

  sub return_subscriptionsets {
    return reverse
        sort { $a->{apply_qual}.$a->{set_name} cmp $b->{apply_qual}.$b->{set_name} } @subscriptionsets;
  }

  sub init_subscriptionsets {
    my %params = @_;
    # name = apply_qual / die eindeutige kennung des apply-programms, ...
    # name2 = set_name / der name der subskriptionsgruppe ...
    my $num_subscriptionsets = 0;
    if (($params{mode} =~ /server::instance::replication::subscriptionsets::listsubscriptionsets/) ||
        ($params{mode} =~ /server::instance::replication::subscriptionsets::subscriptionlatency/)) {
      # http://publib.boulder.ibm.com/infocenter/db2luw/v9r7/index.jsp?topic=%2Fcom.ibm.swg.im.iis.db.repl.sqlrepl.doc%2Ftopics%2Fiiyrsrepe2elatency.html
      my $lookback = $params{lookback} || 30;
      my @subscriptionsetresult = $params{handle}->fetchall_array(q{
          SELECT  DISTINCT apply_qual, set_name,
            COALESCE(AVG(
                ((DAYS(endtime) - DAYS(lastrun)) * 86400 +
                (MIDNIGHT_SECONDS(endtime) - MIDNIGHT_SECONDS(lastrun)) +
                (MICROSECOND(endtime) - MICROSECOND(lastrun)) / 1000000.0) +
                ((DAYS(source_conn_time) - DAYS(synchtime)) * 86400 +
                (MIDNIGHT_SECONDS(source_conn_time) - MIDNIGHT_SECONDS(synchtime)) +
                (MICROSECOND(source_conn_time) - MICROSECOND(synchtime)) / 1000000.0)
            ), 0) AS end_to_end_latency,
            COALESCE(MIN(
                ((DAYS(current timestamp) - DAYS(lastrun)) * 86400 +
                (MIDNIGHT_SECONDS(current timestamp) - MIDNIGHT_SECONDS(lastrun)) +
                (MICROSECOND(current timestamp) - MICROSECOND(lastrun)) / 1000000.0)
            ), 0) AS run_lag,
            COALESCE(MIN(
                ((DAYS(current timestamp) - DAYS(lastsuccess)) * 86400 +
                (MIDNIGHT_SECONDS(current timestamp) - MIDNIGHT_SECONDS(lastsuccess)) +
                (MICROSECOND(current timestamp) - MICROSECOND(lastsuccess)) / 1000000.0)
            ), 0) AS success_lag,
            COALESCE(MIN(
                ((DAYS(current timestamp) - DAYS(synchtime)) * 86400 +
                (MIDNIGHT_SECONDS(current timestamp) - MIDNIGHT_SECONDS(synchtime)) +
                (MICROSECOND(current timestamp) - MICROSECOND(synchtime)) / 1000000.0)
            ), 0) AS latency
          FROM asn.ibmsnap_applytrail
          WHERE synchtime > (current timestamp - ? minutes)
          GROUP BY apply_qual, set_name
      }, $lookback);
      #@subscriptionsetresult = map { [split /\s+/] } @{$sample->{data}};
      foreach (@subscriptionsetresult) {
        my ($apply_qual, $set_name, $end_to_end_latency, $run_lag, $success_lag, $latency) = @{$_};
        if ($params{regexp}) {
          my $matchname = $apply_qual.'/'.$set_name;
          next if $params{selectname} && $matchname !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $apply_qual.'/'.$set_name;
        }
        #next if $params{name2} && lc $params{name2} ne lc $set_name;
        my %thisparams = %params;
        $thisparams{apply_qual} = $apply_qual;
        $thisparams{set_name} = $set_name;
        $thisparams{end_to_end_latency} = $end_to_end_latency;
        $thisparams{run_lag} = $run_lag;
        $thisparams{success_lag} = $success_lag;
        $thisparams{latency} = $latency;
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
  foreach my $k (qw(apply_qual set_name end_to_end_latency run_lag success_lag latency)) {
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
          sprintf "%s/%s latency is %.3fs",
          $self->{apply_qual}, $self->{set_name}, $self->{end_to_end_latency});
      $self->add_perfdata(sprintf "%s_%s_end_to_end_latency=%.3fs;%s;%s",
          $self->{apply_qual}, $self->{set_name}, $self->{end_to_end_latency},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "%s_%s_run_lag=%.3fs",
          $self->{apply_qual}, $self->{set_name}, $self->{run_lag});
      $self->add_perfdata(sprintf "%s_%s_success_lag=%.3fs",
          $self->{apply_qual}, $self->{set_name}, $self->{success_lag});
      $self->add_perfdata(sprintf "%s_%s_latency=%.3fs",
          $self->{apply_qual}, $self->{set_name}, $self->{latency});
    }
  }
}


1;
