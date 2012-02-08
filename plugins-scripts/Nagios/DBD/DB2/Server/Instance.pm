package DBD::DB2::Server::Instance;

use strict;

our @ISA = qw(DBD::DB2::Server);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    databases => [],
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  if ($params{mode} =~ /server::instance::sga/) {
    $self->{sga} = DBD::DB2::Server::Instance::SGA->new(%params);
  } elsif (($params{mode} =~ /server::instance::database/) ||
      ($params{mode} =~ /server::instance::listdatabases/)) {
    DBD::DB2::Server::Instance::Database::init_databases(%params);
    if (my @databases =
        DBD::DB2::Server::Instance::Database::return_databases()) {
      $self->{databases} = \@databases;
    } else {
      $self->add_nagios_critical("unable to aquire database info");
    }
  } elsif (($params{mode} =~ /server::instance::replication::capturelatency/)) {
    my $lookback = $params{lookback} || 30;
    $self->{capture_latency} = $params{handle}->fetchrow_array(q{
        SELECT
            COALESCE(AVG(TIMESTAMPDIFF(1, CHAR((monitor_time - synctime)))), 0)
        FROM
            asn.ibmsnap_capmon 
        WHERE 
            monitor_time > (current timestamp - ? minutes)}, $lookback);
    if (! defined $self->{delay}) {
      $self->add_nagios_critical("unable to aquire delay info");
    }
  } elsif (($params{mode} =~ /server::instance::replication::subscriptionlatency/)) {
    my $lookback = $params{lookback} || 30;
    # reihenweise pro set-->neue klasse
    $self->{subscription_latency} = $params{handle}->fetchrow_array(q{
SELECT ACTIVATE, STATUS, APPLY_QUAL, SET_NAME, WHOS_ON_FIRST,
SECOND(CURRENT TIMESTAMP - LASTRUN) +
((MINUTE(CURRENT TIMESTAMP) - MINUTE(LASTRUN)) * 60) +
((HOUR (CURRENT TIMESTAMP) - HOUR (LASTRUN)) * 3600) +
((DAYS (CURRENT TIMESTAMP) - DAYS (LASTRUN)) * 86400)
AS SET_RUN_LAG,
SECOND(CURRENT TIMESTAMP - LASTSUCCESS) +
((MINUTE(CURRENT TIMESTAMP) - MINUTE(LASTSUCCESS)) * 60) +
((HOUR (CURRENT TIMESTAMP) - HOUR (LASTSUCCESS)) * 3600) +
((DAYS (CURRENT TIMESTAMP) - DAYS (LASTSUCCESS)) * 86400)
AS SET_SUCCESS_LAG,
SECOND(CURRENT TIMESTAMP - SYNCHTIME) +
((MINUTE(CURRENT TIMESTAMP) - MINUTE(SYNCHTIME)) * 60) +
((HOUR (CURRENT TIMESTAMP) - HOUR (SYNCHTIME)) * 3600) +
((DAYS (CURRENT TIMESTAMP) - DAYS (SYNCHTIME)) * 86400)
AS SET_LATENCY
FROM ASN.IBMSNAP_SUBS_SET
WHERE APPLY_QUAL = ?
AND SET_NAME = ?
    });

  } elsif (($params{mode} =~ /server::instance::replication/)) {
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::listdatabases/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{databases}}) {
        printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::instance::database/) {
      foreach (@{$self->{databases}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::replication::capturelatency/) {
      $self->add_nagios(
          $self->check_thresholds($self->{capture_latency}, "10", "60"),
              sprintf "capture latency at %.2fs", $self->{capture_latency});
      $self->add_perfdata(sprintf "capture_latency=%.2f%;%s;%s",
          $self->{capture_latency},
          $self->{warningrange}, $self->{criticalrange});

    } elsif ($params{mode} =~ /server::instance::replication/) {
    }
  }
}


1;
