package DBD::DB2::Server;

use strict;
use Time::HiRes;
use Time::Local;
use IO::File;
use File::Copy 'cp';
use Data::Dumper;


{
  our $verbose = 0;
  our $scream = 0; # scream if something is not implemented
  our $my_modules_dyn_dir = ""; # where we look for self-written extensions

  my @servers = ();
  my $initerrors = undef;

  sub add_server {
    push(@servers, shift);
  }

  sub return_servers {
    return @servers;
  }
  
  sub return_first_server() {
    return $servers[0];
  }

}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    method => $params{method} || "dbi",
    hostname => $params{hostname},
    database => $params{database},
    username => $params{username},
    password => $params{password},
    port => $params{port} || 50000,
    timeout => $params{timeout},
    warningrange => $params{warningrange},
    criticalrange => $params{criticalrange},
    verbose => $params{verbose},
    report => $params{report},
    negate => $params{negate},
    version => 'unknown',
    os => 'unknown',
    instance => undef,
    databases => [],
    handle => undef,
  };
  bless $self, $class;
  $self->init_nagios();
  if ($self->dbconnect(%params)) {
    $self->{version} = $self->{handle}->fetchrow_array(
        q{ SELECT prod_release FROM sysibmadm.env_prod_info });
    #$self->{os} = $self->{handle}->fetchrow_array(
    #    q{ SELECT dbms_utility.port_string FROM dual });
    $self->{dbuser} = $self->{handle}->fetchrow_array(
        q{ SELECT current_user FROM sysibm.sysdummy1 });
    #$self->{thread} = $self->{handle}->fetchrow_array(
    #    q{ SELECT thread# FROM v$instance });
    #$self->{parallel} = $self->{handle}->fetchrow_array(
    #    q{ SELECT parallel FROM v$instance });
    DBD::DB2::Server::add_server($self);
    $self->init(%params);
  }
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $params{handle} = $self->{handle};
  $self->set_global_db_thresholds(\%params);
  if ($params{mode} =~ /^server::instance/) {
    $self->{instance} = DBD::DB2::Server::Instance->new(%params);
  } elsif ($params{mode} =~ /^server::database/) {
    $self->{database} = DBD::DB2::Server::Database->new(%params);
  } elsif ($params{mode} =~ /^server::sqlruntime/) {
    $self->set_local_db_thresholds(%params);
    my $tic = Time::HiRes::time();
      @{$self->{genericsql}} =
          $self->{handle}->fetchrow_array($params{selectname});
    $self->{runtime} = Time::HiRes::time() - $tic;
  } elsif ($params{mode} =~ /^server::sql/) {
    $self->set_local_db_thresholds(%params);
    if ($params{regexp}) {
      # sql output is treated as text
      if ($params{name2} eq $params{name}) {
        $self->add_nagios_unknown(sprintf "where's the regexp????");
      } else {
        $self->{genericsql} =
            $self->{handle}->fetchrow_array($params{selectname});
        if (! defined $self->{genericsql}) {
          $self->add_nagios_unknown(sprintf "got no valid response for %s",
              $params{selectname});
        }
      }
    } else {
      # sql output must be a number (or array of numbers)
      @{$self->{genericsql}} =
          $self->{handle}->fetchrow_array($params{selectname});
      if (! (defined $self->{genericsql} &&
          (scalar(grep { /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/ } @{$self->{genericsql}})) ==
          scalar(@{$self->{genericsql}}))) {
        $self->add_nagios_unknown(sprintf "got no valid response for %s",
            $params{selectname});
      } else {
        # name2 in array
        # units in array
      }
    }
  } elsif ($params{mode} =~ /^server::connectiontime/) {
    $self->{connection_time} = $self->{tac} - $self->{tic};
  } elsif ($params{mode} =~ /^my::([^:.]+)/) {
    my $class = $1;
    my $loaderror = undef;
    substr($class, 0, 1) = uc substr($class, 0, 1);
    foreach my $libpath (split(":", $DBD::DB2::Server::my_modules_dyn_dir)) {
      foreach my $extmod (glob $libpath."/CheckDB2Health*.pm") {
        eval {
          $self->trace(sprintf "loading module %s", $extmod);
          require $extmod;
        };
        if ($@) {
          $loaderror = $extmod;
          $self->trace(sprintf "failed loading module %s: %s", $extmod, $@);
        }
      }
    }
    my $obj = {
        handle => $params{handle},
        warningrange => $params{warningrange},
        criticalrange => $params{criticalrange},
    };
    bless $obj, "My$class";
    $self->{my} = $obj;
    if ($self->{my}->isa("DBD::DB2::Server")) {
      my $dos_init = $self->can("init");
      my $dos_nagios = $self->can("nagios");
      my $my_init = $self->{my}->can("init");
      my $my_nagios = $self->{my}->can("nagios");
      if ($my_init == $dos_init) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs an init() method", ref($self->{my}));
      } elsif ($my_nagios == $dos_nagios) {
          $self->add_nagios_unknown(
              sprintf "Class %s needs a nagios() method", ref($self->{my}));
      } else {
        $self->{my}->init_nagios(%params);
        $self->{my}->init(%params);
      }
    } else {
      $self->add_nagios_unknown(
          sprintf "Class %s is not a subclass of DBD::DB2::Server%s", 
              ref($self->{my}),
              $loaderror ? sprintf " (syntax error in %s?)", $loaderror : "" );
    }
  } else {
    printf "broken mode %s\n", $params{mode};
  }
}

sub dump {
  my $self = shift;
  my $message = shift || "";
  printf "%s %s\n", $message, Data::Dumper::Dumper($self);
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /^server::instance/) {
      $self->{instance}->nagios(%params);
      $self->merge_nagios($self->{instance});
    } elsif ($params{mode} =~ /^server::database/) {
      $self->{database}->nagios(%params);
      $self->merge_nagios($self->{database});
    } elsif ($params{mode} =~ /^server::connectiontime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connection_time}, 1, 5),
          sprintf "%.2f seconds to connect as %s",
              $self->{connection_time}, $self->{dbuser});
      $self->add_perfdata(sprintf "connection_time=%.4f;%d;%d",
          $self->{connection_time},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::sqlruntime/) {
      $self->add_nagios(
          $self->check_thresholds($self->{runtime}, 1, 5),
          sprintf "%.2f seconds to execute %s",
              $self->{runtime},
              $params{name2} ? $params{name2} : $params{selectname});
      $self->add_perfdata(sprintf "sql_runtime=%.4f;%d;%d",
          $self->{runtime},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /^server::sql/) {
      if ($params{regexp}) {
        if (substr($params{name2}, 0, 1) eq '!') {
          $params{name2} =~ s/^!//;
          if ($self->{genericsql} !~ /$params{name2}/) {
            $self->add_nagios_ok(
                sprintf "output %s does not match pattern %s",
                    $self->{genericsql}, $params{name2});
          } else {
            $self->add_nagios_critical(
                sprintf "output %s matches pattern %s",
                    $self->{genericsql}, $params{name2});
          }
        } else {
          if ($self->{genericsql} =~ /$params{name2}/) {
            $self->add_nagios_ok(
                sprintf "output %s matches pattern %s",
                    $self->{genericsql}, $params{name2});
          } else {
            $self->add_nagios_critical(
                sprintf "output %s does not match pattern %s",
                    $self->{genericsql}, $params{name2});
          }
        }
      } else {
        $self->add_nagios(
            # the first item in the list will trigger the threshold values
            $self->check_thresholds($self->{genericsql}[0], 1, 5),
                sprintf "%s: %s%s",
                $params{name2} ? lc $params{name2} : lc $params{selectname},
                # float as float, integers as integers
                join(" ", map {
                    (sprintf("%d", $_) eq $_) ? $_ : sprintf("%f", $_)
                } @{$self->{genericsql}}),
                $params{units} ? $params{units} : "");
        my $i = 0;
        # workaround... getting the column names from the database would be nicer
        my @names2_arr = split(/\s+/, $params{name2});
        foreach my $t (@{$self->{genericsql}}) {
          $self->add_perfdata(sprintf "\'%s\'=%s%s;%s;%s",
              $names2_arr[$i] ? lc $names2_arr[$i] : lc $params{selectname},
              # float as float, integers as integers
              (sprintf("%d", $t) eq $t) ? $t : sprintf("%f", $t),
              $params{units} ? $params{units} : "",
            ($i == 0) ? $self->{warningrange} : "",
              ($i == 0) ? $self->{criticalrange} : ""
          );
          $i++;
        }
      }
    } elsif ($params{mode} =~ /^my::([^:.]+)/) {
      $self->{my}->nagios(%params);
      $self->merge_nagios($self->{my});
    }
  }
}


sub init_nagios {
  my $self = shift;
  no strict 'refs';
  if (! ref($self)) {
    my $nagiosvar = $self."::nagios";
    my $nagioslevelvar = $self."::nagios_level";
    $$nagiosvar = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $$nagioslevelvar = $ERRORS{OK},
  } else {
    $self->{nagios} = {
      messages => {
        0 => [],
        1 => [],
        2 => [],
        3 => [],
      },
      perfdata => [],
    };
    $self->{nagios_level} = $ERRORS{OK},
  }
}

sub check_thresholds {
  my $self = shift;
  my $value = shift;
  my $defaultwarningrange = shift;
  my $defaultcriticalrange = shift;
  my $level = $ERRORS{OK};
  $self->{warningrange} = defined $self->{warningrange} ?
      $self->{warningrange} : $defaultwarningrange;
  $self->{criticalrange} = defined $self->{criticalrange} ?
      $self->{criticalrange} : $defaultcriticalrange;

  if ($self->{warningrange} =~ /^([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = 10, warn if > 10 or < 0
    $level = $ERRORS{WARNING}
        if ($value > $1 || $value < 0);
  } elsif ($self->{warningrange} =~ /^([-+]?[0-9]*\.?[0-9]+):$/) {
    # warning = 10:, warn if < 10
    $level = $ERRORS{WARNING}
        if ($value < $1);
  } elsif ($self->{warningrange} =~ /^~:([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = ~:10, warn if > 10
    $level = $ERRORS{WARNING}
        if ($value > $1);
  } elsif ($self->{warningrange} =~ /^([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = 10:20, warn if < 10 or > 20
    $level = $ERRORS{WARNING}
        if ($value < $1 || $value > $2);
  } elsif ($self->{warningrange} =~ /^@([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # warning = @10:20, warn if >= 10 and <= 20
    $level = $ERRORS{WARNING}
        if ($value >= $1 && $value <= $2);
  }
  if ($self->{criticalrange} =~ /^([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = 10, crit if > 10 or < 0
    $level = $ERRORS{CRITICAL}
        if ($value > $1 || $value < 0);
  } elsif ($self->{criticalrange} =~ /^([-+]?[0-9]*\.?[0-9]+):$/) {
    # critical = 10:, crit if < 10
    $level = $ERRORS{CRITICAL}
        if ($value < $1);
  } elsif ($self->{criticalrange} =~ /^~:([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = ~:10, crit if > 10
    $level = $ERRORS{CRITICAL}
        if ($value > $1);
  } elsif ($self->{criticalrange} =~ /^([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = 10:20, crit if < 10 or > 20
    $level = $ERRORS{CRITICAL}
        if ($value < $1 || $value > $2);
  } elsif ($self->{criticalrange} =~ /^@([-+]?[0-9]*\.?[0-9]+):([-+]?[0-9]*\.?[0-9]+)$/) {
    # critical = @10:20, crit if >= 10 and <= 20
    $level = $ERRORS{CRITICAL}
        if ($value >= $1 && $value <= $2);
  }
  return $level;
  #
  # syntax error must be reported with returncode -1
  #
}

sub add_nagios {
  my $self = shift;
  my $level = shift;
  my $message = shift;
  push(@{$self->{nagios}->{messages}->{$level}}, $message);
  # recalc current level
  foreach my $llevel (qw(CRITICAL WARNING UNKNOWN OK)) {
    if (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$llevel}}})) {
      $self->{nagios_level} = $ERRORS{$llevel};
    }
  }
}

sub add_nagios_ok {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{OK}, $message);
}

sub add_nagios_warning {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{WARNING}, $message);
}

sub add_nagios_critical {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{CRITICAL}, $message);
}

sub add_nagios_unknown {
  my $self = shift;
  my $message = shift;
  $self->add_nagios($ERRORS{UNKNOWN}, $message);
}

sub add_perfdata {
  my $self = shift;
  my $data = shift;
  push(@{$self->{nagios}->{perfdata}}, $data);
}

sub merge_nagios {
  my $self = shift;
  my $child = shift;
  foreach my $level (0..3) {
    foreach (@{$child->{nagios}->{messages}->{$level}}) {
      $self->add_nagios($level, $_);
    }
    #push(@{$self->{nagios}->{messages}->{$level}},
    #    @{$child->{nagios}->{messages}->{$level}});
  }
  push(@{$self->{nagios}->{perfdata}}, @{$child->{nagios}->{perfdata}});
}

sub calculate_result {
  my $self = shift;
  my $labels = shift || {};
  my $multiline = 0;
  map {
    $self->{nagios_level} = $ERRORS{$_} if
        (scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}}));
  } ("OK", "UNKNOWN", "WARNING", "CRITICAL");
  if ($ENV{NRPE_MULTILINESUPPORT} &&
      length join(" ", @{$self->{nagios}->{perfdata}}) > 200) {
    $multiline = 1;
  }
  my $all_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("CRITICAL", "WARNING", "UNKNOWN", "OK"));
  my $bad_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("CRITICAL", "WARNING", "UNKNOWN"));
  my $good_messages = join(($multiline ? "\n" : ", "), map {
      join(($multiline ? "\n" : ", "), @{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } grep {
      scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
  } ("OK"));
  my $all_messages_short = $bad_messages ? $bad_messages : 'no problems';
  # if mode = my-....
  # and there are some ok-messages
  # output them instead of "no problems"
  if ($self->{mode} =~ /^my\:\:/ && $good_messages) {
    $all_messages_short = $bad_messages ? $bad_messages : $good_messages;
  }
  my $all_messages_html = "<table style=\"border-collapse: collapse;\">".
      join("", map {
          my $level = $_;
          join("", map {
              sprintf "<tr valign=\"top\"><td class=\"service%s\">%s</td></tr>",
              $level, $_;
          } @{$self->{nagios}->{messages}->{$ERRORS{$_}}});
      } grep {
          scalar(@{$self->{nagios}->{messages}->{$ERRORS{$_}}})
      } ("CRITICAL", "WARNING", "UNKNOWN", "OK")).
  "</table>";
  if (exists $self->{identstring}) {
    $self->{nagios_message} .= $self->{identstring};
  }
  if ($self->{report} eq "long") {
    $self->{nagios_message} .= $all_messages;
  } elsif ($self->{report} eq "short") {
    $self->{nagios_message} .= $all_messages_short;
  } elsif ($self->{report} eq "html") {
    $self->{nagios_message} .= $all_messages_short."\n".$all_messages_html;
  }
  foreach my $from (keys %{$self->{negate}}) {
    if ((uc $from) =~ /^(OK|WARNING|CRITICAL|UNKNOWN)$/ &&
        (uc $self->{negate}->{$from}) =~ /^(OK|WARNING|CRITICAL|UNKNOWN)$/) {
      if ($self->{nagios_level} == $ERRORS{uc $from}) {
        $self->{nagios_level} = $ERRORS{uc $self->{negate}->{$from}};
      }
    }
  }
  if ($self->{labelformat} eq "pnp4nagios") {
    $self->{perfdata} = join(" ", @{$self->{nagios}->{perfdata}});
  } else {
    $self->{perfdata} = join(" ", map {
        my $perfdata = $_;
        if ($perfdata =~ /^(.*?)=(.*)/) {
          my $label = $1;
          my $data = $2;
          if (exists $labels->{$label} &&
              exists $labels->{$label}->{$self->{labelformat}}) {
            $labels->{$label}->{$self->{labelformat}}."=".$data;
          } else {
            $perfdata;
          }
        } else {
          $perfdata;
        }
    } @{$self->{nagios}->{perfdata}});
  }
}

sub set_global_db_thresholds {
  my $self = shift;
  my $params = shift;
  my $warning = undef;
  my $critical = undef;
  return unless defined $params->{dbthresholds};
  $params->{name0} = $params->{dbthresholds};
  # :pluginmode   :name     :warning    :critical
  # mode          empty     
  # 
  eval {
    if ($self->{handle}->fetchrow_array(q{
        SELECT tabname FROM syscat.tables
        WHERE tabname = 'CHECK_DB2_HEALTH_THRESHOLDS'
      })) {
      my @dbthresholds = $self->{handle}->fetchall_array(q{
          SELECT * FROM check_db2_health_thresholds
      });
      $params->{dbthresholds} = \@dbthresholds;
      foreach (@dbthresholds) { 
        if (($_->[0] eq $params->{cmdlinemode}) &&
            (! defined $_->[1] || ! $_->[1])) { 
          ($warning, $critical) = ($_->[2], $_->[3]);
        }
      }
    }
  };
  if (! $@) {
    if ($warning) {
      $params->{warningrange} = $warning;
      $self->trace("read warningthreshold %s from database", $warning);
    }
    if ($critical) {
      $params->{criticalrange} = $critical;
      $self->trace("read criticalthreshold %s from database", $critical);
    }
  }
}

sub set_local_db_thresholds {
  my $self = shift;
  my %params = @_;
  my $warning = undef;
  my $critical = undef;
  # :pluginmode   :name     :warning    :critical
  # mode          name0
  # mode          name2
  # mode          name
  #
  # first: argument of --dbthresholds, it it exists
  # second: --name2
  # third: --name
  if (ref($params{dbthresholds}) eq 'ARRAY') {
    my $marker;
    foreach (@{$params{dbthresholds}}) {
      if ($_->[0] eq $params{cmdlinemode}) {
        if (defined $_->[1] && $params{name0} && $_->[1] eq $params{name0}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name0};
          last;
        } elsif (defined $_->[1] && $params{name2} && $_->[1] eq $params{name2}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name2};
          last;
        } elsif (defined $_->[1] && $params{name} && $_->[1] eq $params{name}) {
          ($warning, $critical) = ($_->[2], $_->[3]);
          $marker = $params{name};
          last;
        }
      }
    }
    if ($warning) {
      $self->{warningrange} = $warning;
      $self->trace("read warningthreshold %s for %s from database",
         $marker, $warning);
    }
    if ($critical) {
      $self->{criticalrange} = $critical;
      $self->trace("read criticalthreshold %s for %s from database",
          $marker, $critical);
    }
  }
}

sub debug {
  my $self = shift;
  my $msg = shift;
  if ($DBD::DB2::Server::verbose) {
    printf "%s %s\n", $msg, ref($self);
  }
}

sub dbconnect {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  $self->{tic} = Time::HiRes::time();
  $self->{handle} = DBD::DB2::Server::Connection->new(%params);
  if ($self->{handle}->{errstr}) {
    if ($self->{handle}->{errstr} eq "alarm\n") {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "connection could not be established within %d seconds",
              $self->{timeout});
    } else {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "cannot connect to %s. %s",
          ($self->{hostname} || $self->{database}), $self->{handle}->{errstr});
      $retval = undef;
    }
  } else {
    $retval = $self->{handle};
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub trace {
  my $self = shift;
  my $format = shift;
  $self->{trace} = -f "/tmp/check_db2_health.trace" ? 1 : 0;
  if ($self->{verbose}) {
    printf("%s: ", scalar localtime);
    printf($format, @_);
  }
  if ($self->{trace}) {
    my $logfh = new IO::File;
    $logfh->autoflush(1);
    if ($logfh->open("/tmp/check_db2_health.trace", "a")) {
      $logfh->printf("%s: ", scalar localtime);
      $logfh->printf($format, @_);
      $logfh->printf("\n");
      $logfh->close();
    }
  }
}

sub DESTROY {
  my $self = shift;
  my $handle1 = "null";
  my $handle2 = "null";
  if (defined $self->{handle}) {
    $handle1 = ref($self->{handle});
    if (defined $self->{handle}->{handle}) {
      $handle2 = ref($self->{handle}->{handle});
    }
  }
  $self->trace(sprintf "DESTROY %s with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::DB2::Server") {
  }
  $self->trace(sprintf "DESTROY %s exit with handle %s %s", ref($self), $handle1, $handle2);
  if (ref($self) eq "DBD::DB2::Server") {
    #printf "humpftata\n";
  }
}

sub save_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  my $mode = $params{mode};
  if ($params{connect} && $params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  } elsif ($params{connect}) {
    # just to be sure
    $params{connect} =~ s/\//_/g;
  } 
  if ($^O =~ /MSWin/) {
    $mode =~ s/::/_/g;
    $params{statefilesdir} = $self->system_vartmpdir();
  }
  if (! -d $params{statefilesdir}) {
    eval {
      use File::Path;
      mkpath $params{statefilesdir};
    };
  }
  if ($@ || ! -w $params{statefilesdir}) {
    $self->add_nagios($ERRORS{CRITICAL},
        sprintf "statefilesdir %s does not exist or is not writable\n",
        $params{statefilesdir});
    return;
  }
  my $statefile = sprintf "%s", $mode;
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{hostname} ? "_".$params{hostname} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  $statefile = sprintf "%s/%s", $params{statefilesdir}, $statefile;
  if (open(STATE, ">$statefile")) {
    if ((ref($params{save}) eq "HASH") && exists $params{save}->{timestamp}) {
      $params{save}->{localtime} = scalar localtime $params{save}->{timestamp};
    }
    printf STATE Data::Dumper::Dumper($params{save});
    close STATE;
  } else {
    $self->add_nagios($ERRORS{CRITICAL},
        sprintf "statefile %s is not writable", $statefile);
  }
  $self->debug(sprintf "saved %s to %s",
      Data::Dumper::Dumper($params{save}), $statefile);
}

sub load_state {
  my $self = shift;
  my %params = @_;
  my $extension = "";
  my $mode = $params{mode};
  if ($params{connect} && $params{connect} =~ /(\w+)\/(\w+)@(\w+)/) {
    $params{connect} = $3;
  } elsif ($params{connect}) {
    # just to be sure
    $params{connect} =~ s/\//_/g;
  }
  if ($^O =~ /MSWin/) {
    $mode =~ s/::/_/g;
    $params{statefilesdir} = $self->system_vartmpdir();
  }
  my $statefile = sprintf "%s", $mode;
  $extension .= $params{differenciator} ? "_".$params{differenciator} : "";
  $extension .= $params{database} ? "_".$params{database} : "";
  $extension .= $params{hostname} ? "_".$params{hostname} : "";
  $extension .= $params{tablespace} ? "_".$params{tablespace} : "";
  $extension .= $params{datafile} ? "_".$params{datafile} : "";
  $extension .= $params{name} ? "_".$params{name} : "";
  $extension =~ s/\//_/g;
  $extension =~ s/\(/_/g;
  $extension =~ s/\)/_/g;
  $extension =~ s/\*/_/g;
  $extension =~ s/\s/_/g;
  $statefile .= $extension;
  $statefile = lc $statefile;
  $statefile = sprintf "%s/%s", $params{statefilesdir}, $statefile;
  if ( -f $statefile) {
    our $VAR1;
    eval {
      require $statefile;
    };
    if($@) {
      $self->add_nagios($ERRORS{CRITICAL},
          sprintf "statefile %s is corrupt", $statefile);
    }
    $self->debug(sprintf "load %s", Data::Dumper::Dumper($VAR1));
    return $VAR1;
  } else {
    return undef;
  }
}

sub valdiff {
  my $self = shift;
  my $pparams = shift;
  my %params = %{$pparams};
  my @keys = @_;
  my $now = time;
  my $last_values = $self->load_state(%params) || eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = 0;
    }
    $empty_events->{timestamp} = 0;
    if ($params{lookback}) {
      $empty_events->{lookback_history} = {};
    }
    $empty_events;
  };
  foreach (@keys) {
    if ($params{lookback}) {
      # find a last_value in the history which fits lookback best
      # and overwrite $last_values->{$_} with historic data
      if (exists $last_values->{lookback_history}->{$_}) {
        foreach my $date (sort {$a <=> $b} keys %{$last_values->{lookback_history}->{$_}}) {
          if ($date >= ($now - $params{lookback})) {
            $last_values->{$_} = $last_values->{lookback_history}->{$_}->{$date};
            $last_values->{timestamp} = $date;
            last;
          } else {
            delete $last_values->{lookback_history}->{$_}->{$date};
          }
        }
      }
    }
    $last_values->{$_} = 0 if ! exists $last_values->{$_};
    if ($self->{$_} >= $last_values->{$_}) {
      $self->{'delta_'.$_} = $self->{$_} - $last_values->{$_};
    } else {
      # vermutlich db restart und zaehler alle auf null
      $self->{'delta_'.$_} = $self->{$_};
    }
    $self->debug(sprintf "delta_%s %f", $_, $self->{'delta_'.$_});
  }
  $self->{'delta_timestamp'} = $now - $last_values->{timestamp};
  $params{save} = eval {
    my $empty_events = {};
    foreach (@keys) {
      $empty_events->{$_} = $self->{$_};
    }
    $empty_events->{timestamp} = $now;
    if ($params{lookback}) {
      $empty_events->{lookback_history} = $last_values->{lookback_history};
      foreach (@keys) {
        $empty_events->{lookback_history}->{$_}->{$now} = $self->{$_};
      }
    }
    $empty_events;
  };
  $self->save_state(%params);
}

sub requires_version {
  my $self = shift;
  my $version = shift;
  my @instances = DBD::DB2::Server::return_servers();
  my $instversion = $instances[0]->{version};
  if (! $self->version_is_minimum($version)) {
    $self->add_nagios($ERRORS{UNKNOWN}, 
        sprintf "not implemented/possible for DB2 release %s", $instversion);
  }
}

sub version_is_minimum {
  # the current version is newer or equal
  my $self = shift;
  my $version = shift;
  my $newer = 1;
  my @instances = DBD::DB2::Server::return_servers();
  my @v1 = map { $_ eq "x" ? 0 : $_ } split(/\./, $version);
  my @v2 = split(/\./, $instances[0]->{version});
  if (scalar(@v1) > scalar(@v2)) {
    push(@v2, (0) x (scalar(@v1) - scalar(@v2)));
  } elsif (scalar(@v2) > scalar(@v1)) {
    push(@v1, (0) x (scalar(@v2) - scalar(@v1)));
  }
  foreach my $pos (0..$#v1) {
    if ($v2[$pos] > $v1[$pos]) {
      $newer = 1;
      last;
    } elsif ($v2[$pos] < $v1[$pos]) {
      $newer = 0;
      last;
    }
  }
  #printf STDERR "check if %s os minimum %s\n", join(".", @v2), join(".", @v1);
  return $newer;
}

sub instance_rac {
  my $self = shift;
  my @instances = DBD::DB2::Server::return_servers();
  return (lc $instances[0]->{parallel} eq "yes") ? 1 : 0;
}

sub instance_thread {
  my $self = shift;
  my @instances = DBD::DB2::Server::return_servers();
  return $instances[0]->{thread};
}

sub windows_server {
  my $self = shift;
  my @instances = DBD::DB2::Server::return_servers();
  if ($instances[0]->{os} =~ /Win/i) {
    return 1;
  } else {
    return 0;
  }
}

sub system_vartmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $self->system_tmpdir();
  } else {
    return "/var/tmp/check_db2_health";
  }
}

sub system_oldvartmpdir {
  my $self = shift;
  return "/tmp";
}

sub system_tmpdir {
  my $self = shift;
  if ($^O =~ /MSWin/) {
    return $ENV{TEMP} if defined $ENV{TEMP};
    return $ENV{TMP} if defined $ENV{TMP};
    return File::Spec->catfile($ENV{windir}, 'Temp')
        if defined $ENV{windir};
    return 'C:\Temp';
  } else {
    return "/tmp";
  }
}

sub convert_db2_timestamp {
  my $self = shift;
  my $timestamp = shift;
  # 2012-02-08-13.53.18.338770
  if ($timestamp =~ /^(\d\d\d\d)-(\d\d)-(\d\d)-(\d\d)\.(\d\d)\.(\d\d)\.(\d+)?$/ ||
      $timestamp =~ /^(\d\d\d\d)-(\d\d)-(\d\d)\s(\d\d):(\d\d):(\d\d)\.(\d+)?$/) {
    # $sec,$min,$hours,$mday,$mon,$year
    # 6    5    4      3     2    1, mon=0..11
    my $epoch = timelocal($6, $5, $4, $3, $2 - 1, $1) + $7 / 1000000;
    return $epoch;
  } else {
  }
}


package DBD::DB2::Server::Connection;

use strict;

our @ISA = qw(DBD::DB2::Server);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    mode => $params{mode},
    timeout => $params{timeout},
    method => $params{method} || "dbi",
    verbose => $params{verbose},
    hostname => $params{hostname},
    database => $params{database},
    username => $params{username},
    password => $params{password},
    port => $params{port} || 50000,
    db2home => $ENV{DB2_HOME},
    handle => undef,
  };
  bless $self, $class;
  if ($params{method} eq "dbi") {
    bless $self, "DBD::DB2::Server::Connection::Dbi";
  } elsif ($params{method} eq "sqlrelay") {
    bless $self, "DBD::DB2::Server::Connection::Sqlrelay";
  }
  $self->init(%params);
  return $self;
}


package DBD::DB2::Server::Connection::Dbi;

use strict;
use Net::Ping;

our @ISA = qw(DBD::DB2::Server::Connection);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  if ($self->{mode} =~ /^server::tnsping/) {
    # keine ahnung ob das bei db2 zu gebrauchen ist
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      $self->{sid} = $self->{connect};
      $self->{user} ||= time;  # prefer an existing user
      $self->{password} = time;
    }
  } else {
    # entweder katalogisiert oder nicht
    # database username password
    # database username password hostname port
    if (! $self->{database} || ! $self->{username} || ! $self->{password}) {
      $self->{errstr} = "Please specify database, username and password";
      return undef;
    }
    $self->{dsn} = "DBI:DB2:";
    if (! $self->{hostname}) {
      # catalog tcpip node <host-nickname> remote <hostname> server <port>
      # catalog database <remote-db> as <local-nick> at node <host-nickname>
      $self->{dsn} .= $self->{database};
    } else {
      $self->{dsn} .= sprintf "DATABASE=%s; ", $self->{database};
      $self->{dsn} .= sprintf "HOSTNAME=%s; ", $self->{hostname};
      $self->{dsn} .= sprintf "PORT=%d; ", $self->{port};
      $self->{dsn} .= sprintf "PROTOCOL=TCPIP; ";
      $self->{dsn} .= sprintf "UID=%s; ", $self->{username};
      $self->{dsn} .= sprintf "PWD=%s;", $self->{password};
    }
  }
  if (! exists $self->{errstr}) {
    eval {
      require DBI;
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      if ($self->{handle} = DBI->connect(
          $self->{dsn},
          $self->{username},
          $self->{password},
          { RaiseError => 0, AutoCommit => 1, PrintError => 0 })) {
        $retval = $self;
      } else {
        $self->{errstr} = DBI::errstr();
      }
    };
    if ($@) {
      $self->{errstr} = $@;
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  eval {
    $self->trace(sprintf "SQL:\n%s\n", $sql);
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $self->trace(sprintf "ARGS:\n%s\n", Data::Dumper::Dumper(\@arguments));
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    @row = $sth->fetchrow_array();
    $self->trace(sprintf "RESULT:\n%s\n", Data::Dumper::Dumper(\@row));
  }; 
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  if (-f "/tmp/check_db2_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_db2_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  eval {
    $self->trace(sprintf "SQL:\n%s\n", $sql);
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $self->trace(sprintf "ARGS:\n%s\n", Data::Dumper::Dumper(\@arguments));
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    $rows = $sth->fetchall_arrayref();
    $self->trace(sprintf "RESULT:\n%s\n", Data::Dumper::Dumper($rows));
  }; 
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  if (-f "/tmp/check_db2_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) = 
        "/tmp/check_db2_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub fetchall_hashref {
  my $self = shift;
  my $sql = shift;
  my $hashkey = shift;
  my @arguments = @_;
  my $sth = undef;
  my $hashref = undef;
  eval {
DBI->trace(3);

    $sth = $self->{handle}->prepare($sql);
$sth->{db2_concurrency} = 'SQL_CONCUR_READ_ONLY';
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
while (my $orks = $sth->fetchrow_arrayref()) {
printf "doof: %s\n", Data::Dumper::Dumper($orks);
}
    $hashref = $sth->fetchall_hashref($hashkey);
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  return $hashref;
}


sub func {
  my $self = shift;
  $self->{handle}->func(@_);
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  $self->trace(sprintf "disconnecting DBD %s",
      $self->{handle} ? "with handle" : "without handle");
  $self->{handle}->disconnect() if $self->{handle};
}


package DBD::DB2::Server::Connection::Sqlrelay;

use strict;
use Net::Ping;

our @ISA = qw(DBD::DB2::Server::Connection);


sub init {
  my $self = shift;
  my %params = @_;
  my $retval = undef;
  if ($self->{mode} =~ /^server::tnsping/) {
    if (! $self->{connect}) {
      $self->{errstr} = "Please specify a database";
    } else {
      if ($self->{connect} =~ /([\.\w]+):(\d+)/) {
        $self->{host} = $1;
        $self->{port} = $2;
        $self->{socket} = "";
      } elsif ($self->{connect} =~ /([\.\w]+):([\w\/]+)/) {
        $self->{host} = $1;
        $self->{socket} = $2;
        $self->{port} = "";
      }
    }
  } else {
    if (! $self->{connect} || ! $self->{user} || ! $self->{password}) {
      if ($self->{connect} && $self->{connect} =~ /(\w+)\/(\w+)@([\.\w]+):(\d+)/) {
        $self->{user} = $1;
        $self->{password} = $2;
        $self->{host} = $3; 
        $self->{port} = $4;
        $self->{socket} = "";
      } elsif ($self->{connect} && $self->{connect} =~ /(\w+)\/(\w+)@([\.\w]+):([\w\/]+)/) {
        $self->{user} = $1;
        $self->{password} = $2;
        $self->{host} = $3; 
        $self->{socket} = $4;
        $self->{port} = "";
      } else {
        $self->{errstr} = "Please specify database, username and password";
        return undef;
      }
    } else {
      if ($self->{connect} =~ /([\.\w]+):(\d+)/) {
        $self->{host} = $1;
        $self->{port} = $2;
        $self->{socket} = "";
      } elsif ($self->{connect} =~ /([\.\w]+):([\w\/]+)/) {
        $self->{host} = $1;
        $self->{socket} = $2;
        $self->{port} = "";
      } else {
        $self->{errstr} = "Please specify database, username and password";
        return undef;
      }
    }
  }
  if (! exists $self->{errstr}) {
    eval {
      require DBI;
      use POSIX ':signal_h';
      if ($^O =~ /MSWin/) {
        local $SIG{'ALRM'} = sub {
          die "alarm\n";
        };
      } else {
        my $mask = POSIX::SigSet->new( SIGALRM );
        my $action = POSIX::SigAction->new(
            sub { die "alarm\n" ; }, $mask);
        my $oldaction = POSIX::SigAction->new();
        sigaction(SIGALRM ,$action ,$oldaction );
      }
      alarm($self->{timeout} - 1); # 1 second before the global unknown timeout
      if ($self->{handle} = DBI->connect(
          sprintf("DBI:SQLRelay:host=%s;port=%d;socket=%s", $self->{host}, $self->{port}, $self->{socket}),
          $self->{user},
          $self->{password},
          { RaiseError => 1, AutoCommit => 0, PrintError => 1 })) {
        $self->{handle}->do(q{
            ALTER SESSION SET NLS_NUMERIC_CHARACTERS=".," });
        $retval = $self;
        if ($self->{mode} =~ /^server::tnsping/ && $self->{handle}->ping()) {
          # database connected. fake a "unknown user"
          $self->{errstr} = "ERR: unknown user";
        }
      } else {
        $self->{errstr} = DBI::errstr();
      }
    };
    if ($@) {
      $self->{errstr} = $@;
      $self->{errstr} =~ s/at [\w\/\.]+ line \d+.*//g;
      $retval = undef;
    }
  }
  $self->{tac} = Time::HiRes::time();
  return $retval;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my @row = ();
  $self->trace(sprintf "fetchrow_array: %s", $sql);
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    @row = $sth->fetchrow_array();
  };
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
  }
  if (-f "/tmp/check_db2_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_db2_health_simulation/".$self->{mode}; <> };
    @row = split(/\s+/, (split(/\n/, $simulation))[0]);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $sth = undef;
  my $rows = undef;
  $self->trace(sprintf "fetchall_array: %s", $sql);
  eval {
    $sth = $self->{handle}->prepare($sql);
    if (scalar(@arguments)) {
      $sth->execute(@arguments);
    } else {
      $sth->execute();
    }
    $rows = $sth->fetchall_arrayref();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
  if (-f "/tmp/check_db2_health_simulation/".$self->{mode}) {
    my $simulation = do { local (@ARGV, $/) =
        "/tmp/check_db2_health_simulation/".$self->{mode}; <> };
    @{$rows} = map { [ split(/\s+/, $_) ] } split(/\n/, $simulation);
  }
  return @{$rows};
}

sub func {
  my $self = shift;
  $self->{handle}->func(@_);
}


sub execute {
  my $self = shift;
  my $sql = shift;
  eval {
    my $sth = $self->{handle}->prepare($sql);
    $sth->execute();
  };
  if ($@) {
    printf STDERR "bumm %s\n", $@;
  }
}

sub DESTROY {
  my $self = shift;
  #$self->trace(sprintf "disconnecting DBD %s",
  #    $self->{handle} ? "with handle" : "without handle");
  #$self->{handle}->disconnect() if $self->{handle};
}

1;



