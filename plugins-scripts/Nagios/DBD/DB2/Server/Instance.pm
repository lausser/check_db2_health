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
            COALESCE(AVG(
                (DAYS(monitor_time) - DAYS(synchtime)) * 86400 + 
                (MIDNIGHT_SECONDS(monitor_time) - MIDNIGHT_SECONDS(synchtime)) +
                (MICROSECOND(monitor_time) - MICROSECOND(synchtime)) / 1000000.0
            ), 0)
        FROM
            asn.ibmsnap_capmon 
        WHERE 
            monitor_time > (current timestamp - ? minutes)}, $lookback);
    if (! defined $self->{capture_latency}) {
      $self->add_nagios_critical("unable to aquire capture delay info");
    }
  } elsif ($params{mode} =~ /server::instance::replication::subscriptionsets/) {
    DBD::DB2::Server::Instance::Subscriptionset::init_subscriptionsets(%params);
    if (my @subscriptionsets =
        DBD::DB2::Server::Instance::Subscriptionset::return_subscriptionsets()) {
      $self->{subscriptionsets} = \@subscriptionsets;
    } else {
      $self->add_nagios_critical("unable to aquire subscription set info");
    }
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
    } elsif ($params{mode} =~ /server::instance::replication::subscriptionsets::listsubscriptionsets/) {
      my %seen;
      my @unique_subscriptionsets = grep { not $seen{$_->{apply_qual}.$_->{set_name}}++ } @{$self->{subscriptionsets}};
      foreach (sort { $a->{apply_qual} cmp $b->{apply_qual}; } @unique_subscriptionsets) {
        printf "%s %s\n", $_->{apply_qual}, $_->{set_name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::instance::replication::subscriptionsets/) {
      foreach (@{$self->{subscriptionsets}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::replication::capturelatency/) {
      $self->add_nagios(
          $self->check_thresholds($self->{capture_latency}, "10", "60"),
              sprintf "capture latency at %.2fs", $self->{capture_latency});
      $self->add_perfdata(sprintf "capture_latency=%.2fs;%s;%s",
          $self->{capture_latency},
          $self->{warningrange}, $self->{criticalrange});

    } elsif ($params{mode} =~ /server::instance::replication/) {
    }
  }
}


1;
