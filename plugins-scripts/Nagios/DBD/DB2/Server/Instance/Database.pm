package DBD::DB2::Server::Instance::Database;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance);

{
  my @databases = ();
  my $initerrors = undef;

  sub add_database {
    push(@databases, shift);
  }

  sub return_databases {
    return reverse
        sort { $a->{name} cmp $b->{name} } @databases;
  }

  sub init_databases {
    my %params = @_;
    my $num_databases = 0;
    if ($params{mode} =~ /server::instance::listdatabases/) {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
    } elsif (($params{mode} =~ /server::instance::database::listtablespace/) ||
        ($params{mode} =~ /server::instance::database::tablespace/) ||
        ($params{mode} =~ /server::instance::database::bufferpool/)) {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
    } elsif ($params{mode} =~ /server::instance::database::lock/) {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
    } elsif (($params{mode} =~ /server::instance::database::usage/)) {
      my @databaseresult = $params{handle}->fetchrow_array(q{
        CALL GET_DBSIZE_INFO(?, ?, ?, 0)
      });
      my ($snapshot_timestamp, $db_size, $db_capacity)  = 
          $params{handle}->fetchrow_array(q{
              SELECT * FROM SYSTOOLS.STMG_DBSIZE_INFO
          });
      if ($snapshot_timestamp) {
        my %thisparams = %params;
        $thisparams{name} = $params{database};
        $thisparams{snapshot_timestamp} = $snapshot_timestamp;
        $thisparams{db_size} = $db_size;
        $thisparams{db_capacity} = $db_capacity;
        my $database = DBD::DB2::Server::Instance::Database->new(
            %thisparams);
        add_database($database);
        $num_databases++;
      } else {
        $initerrors = 1;
        return undef;
      }
    } else {
      my %thisparams = %params;
      $thisparams{name} = $params{database};
      my $database = DBD::DB2::Server::Instance::Database->new(
          %thisparams);
      add_database($database);
      $num_databases++;
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
    tablespaces => [],
    bufferpools => [],
    partitions => [],
    locks => [],
    snapshot_timestamp => $params{snapshot_timestamp},
    db_size => $params{db_size},
    db_capacity => $params{db_capacity},
    log_utilization => undef,
    srp => undef,
    awp => undef,
    rows_read => undef,
  };
  bless $self, $class;
  $self->init(%params);
  return $self;
}

sub init {
  my $self = shift;
  my %params = @_;
  $self->init_nagios();
  $self->set_local_db_thresholds(%params);
  if (($params{mode} =~ /server::instance::database::listtablespaces/) ||
      ($params{mode} =~ /server::instance::database::tablespace/)) {
    DBD::DB2::Server::Instance::Database::Tablespace::init_tablespaces(%params);
    if (my @tablespaces = 
        DBD::DB2::Server::Instance::Database::Tablespace::return_tablespaces()) {
      $self->{tablespaces} = \@tablespaces;
    } else {
      $self->add_nagios_critical("unable to aquire tablespace info");
    }
  } elsif (($params{mode} =~ /server::instance::database::listbufferpools/) ||
      ($params{mode} =~ /server::instance::database::bufferpool/)) {
    DBD::DB2::Server::Instance::Database::Bufferpool::init_bufferpools(%params);
    if (my @bufferpools = 
        DBD::DB2::Server::Instance::Database::Bufferpool::return_bufferpools()) {
      $self->{bufferpools} = \@bufferpools;
    } else {
      $self->add_nagios_critical("unable to aquire bufferpool info");
    }
  } elsif ($params{mode} =~ /server::instance::database::lock/) {
    DBD::DB2::Server::Instance::Database::Lock::init_locks(%params);
    if (my @locks = 
        DBD::DB2::Server::Instance::Database::Lock::return_locks()) {
      $self->{locks} = \@locks;
    } else {
      $self->add_nagios_critical("unable to aquire lock info");
    }
  } elsif ($params{mode} =~ /server::instance::database::usage/) {
    # http://publib.boulder.ibm.com/infocenter/db2luw/v9/topic/com.ibm.db2.udb.admin.doc/doc/r0011863.htm
    $self->{db_usage} = ($self->{db_size} * 100 / $self->{db_capacity});
  } elsif ($params{mode} =~ /server::instance::database::logutilization/) {
    DBD::DB2::Server::Instance::Database::Partition::init_partitions(%params);
    if (my @partitions = 
        DBD::DB2::Server::Instance::Database::Partition::return_partitions()) {
      $self->{partitions} = \@partitions;
    } else {
      $self->add_nagios_critical("unable to aquire partitions info");
    }
  } elsif ($params{mode} =~ /server::instance::database::srp/) {
    # http://www.dbisoftware.com/blog/db2_performance.php?id=96
    $self->{srp} = $params{handle}->fetchrow_array(q{
        SELECT 
          100 - (((pool_async_data_reads + pool_async_index_reads) * 100 ) /
          (pool_data_p_reads + pool_index_p_reads + 1)) 
        AS
          srp 
        FROM
          sysibmadm.snapdb 
        WHERE 
          db_name = ?
    }, $self->{name});
    if (! defined $self->{srp}) {
      $self->add_nagios_critical("unable to aquire srp info");
    }
  } elsif ($params{mode} =~ /server::instance::database::awp/) {
    # http://www.dbisoftware.com/blog/db2_performance.php?id=117
    $self->{awp} = $params{handle}->fetchrow_array(q{
        SELECT 
          (((pool_async_data_writes + pool_async_index_writes) * 100 ) /
          (pool_data_writes + pool_index_writes + 1)) 
        AS
          awp 
        FROM
          sysibmadm.snapdb 
        WHERE 
          db_name = ?
    }, $self->{name});
    if (! defined $self->{awp}) {
      $self->add_nagios_critical("unable to aquire awp info");
    }
  } elsif ($params{mode} =~ /server::instance::database::indexusage/) {
    ($self->{rows_read}, $self->{rows_selected}) = $params{handle}->fetchrow_array(q{
        SELECT
            rows_read, (rows_selected + rows_inserted + rows_updated + rows_deleted)
        FROM
            sysibmadm.snapdb
    });
    if (! defined $self->{rows_read}) {
      $self->add_nagios_critical("unable to aquire rows info");
    } else {
      $self->{index_usage} = $self->{rows_read} ? 
          ($self->{rows_selected} / $self->{rows_read} * 100) : 100;
    }
  } elsif ($params{mode} =~ /server::instance::database::connectedusers/) {
    #SELECT COUNT(*) FROM sysibmadm.applications WHERE appl_status = 'CONNECTED'
    # there are a lot more stati than "connected". Applications can
    # be connected although being in another state.
    $self->{connected_users} = $self->{handle}->fetchrow_array(q{
        SELECT COUNT(*) FROM sysibmadm.applications
    });
  } elsif ($params{mode} =~ /server::instance::database::lastbackup/) {
    my $sql = undef;
    if ($self->version_is_minimum('9.1')) {
      $sql = sprintf "SELECT (DAYS(current timestamp) - DAYS(last_backup)) * 86400 + (MIDNIGHT_SECONDS(current timestamp) - MIDNIGHT_SECONDS(last_backup)) FROM sysibm.sysdummy1, TABLE(snap_get_db_v91('%s', -2))", $self->{name};
    } else {
      $sql = sprintf "SELECT last_backup FROM table(snap_get_db('%s', -2))",
          $self->{name};
    }
    $self->{last_backup} = $self->{handle}->fetchrow_array($sql);
    $self->{last_backup} = $self->{last_backup} ? $self->{last_backup} : 0;
    # time is measured in days
    $self->{last_backup} = $self->{last_backup} / 86400;
  } elsif ($params{mode} =~ /server::instance::database::staletablerunstats/) {
    @{$self->{stale_tables}} = $self->{handle}->fetchall_array(q{
      SELECT
        LOWER(TRIM(tabschema)||'.'||TRIM(tabname)), 
        (DAYS(current timestamp) - DAYS(COALESCE(stats_time, '1970-01-01-00.00.00'))) * 86400 + (MIDNIGHT_SECONDS(current timestamp) - MIDNIGHT_SECONDS(COALESCE(stats_time, '1970-01-01-00.00.00')))
      FROM
        syscat.tables
      WHERE type in ('S', 'T')
        AND create_time < (current timestamp - 1 day)
    });
    # ('S', 'T') means: only tables and materialized query tables, not views, aliases etc
    # (current timestamp - 1 day) means: don't check objects which were just 
    #  created. wait at least one day so that stats can be generated
    if ($params{selectname} && $params{regexp}) {
      @{$self->{stale_tables}} = grep { $_->[0] =~ $params{selectname} }
          @{$self->{stale_tables}};
    } elsif ($params{selectname}) {
      @{$self->{stale_tables}} = grep { $_->[0] eq $params{selectname} }
          @{$self->{stale_tables}};
    }
    # time is measured in days
    @{$self->{stale_tables}} = map { $_->[1] = $_->[1] / 86400; $_; } @{$self->{stale_tables}};
  } elsif ($params{mode} =~ /server::instance::database::invalidobjects/) {
    @{$self->{invalid_objects}} = $self->{handle}->fetchall_array(q{
        SELECT
            'trigger', trigschema, trigname FROM syscat.triggers
        WHERE
            valid IN ('N', 'X') -- Y=valid, N=invalid, X=inoperative
            --OR trigschema = 'TOOLS' and trigname in ( 'ICM_ACEI','ICM_ACED')
        UNION
        SELECT
            'package', pkgschema, pkgname FROM syscat.packages
        WHERE
            valid IN ('N', 'X') -- Y=valid, N=not valid, X=inoperative
        UNION
        SELECT
            'view', viewschema, viewname FROM syscat.views
        WHERE
            valid IN ('X') -- Y=valid, X=inoperative
            --OR viewschema = 'SYSCAT' and viewname in ( 'XSROBJECTDEP','XSROBJECTS')
        UNION
        SELECT
            'routine', routineschema, routinename FROM syscat.routines
        WHERE
            valid IN ('N', 'X') -- Y=valid, N=invalid, X=inoperative
        UNION
        SELECT
            'table', tabschema, tabname FROM syscat.tables
        WHERE
            status IN ('C', 'X') -- N=normal, C=check pending, X=inoperative
    });
    @{$self->{invalid_triggers}} = grep { $_->[0] eq 'trigger' } @{$self->{invalid_objects}};
    @{$self->{invalid_packages}} = grep { $_->[0] eq 'package' } @{$self->{invalid_objects}};
    @{$self->{invalid_views}} = grep { $_->[0] eq 'view' } @{$self->{invalid_objects}};
    @{$self->{invalid_routines}} = grep { $_->[0] eq 'routine' } @{$self->{invalid_objects}};
    @{$self->{invalid_tables}} = grep { $_->[0] eq 'table' } @{$self->{invalid_objects}};
  } elsif ($params{mode} =~ /server::instance::database::duppackages/) {
    @{$self->{duplicate_packages}} = $self->{handle}->fetchall_array(q{
        SELECT
            SUBSTR(pkgname, 1, 20), COUNT(*) FROM syscat.packages
        GROUP BY pkgname HAVING COUNT(*) > 1 ORDER BY 1
    });
    if ($params{selectname} && $params{regexp}) {
      @{$self->{duplicate_packages}} = grep { $_->[0] =~ $params{selectname} }
          @{$self->{duplicate_packages}};
    } elsif ($params{selectname}) {
      @{$self->{duplicate_packages}} = grep { $_->[0] eq $params{selectname} }
          @{$self->{duplicate_packages}};
    }
  } elsif ($params{mode} =~ /server::instance::database::sortoverflows/) {
    my $sql = undef;
    if ($self->version_is_minimum('9.1')) {
      $sql = sprintf "SELECT sort_overflows FROM TABLE(snap_get_db_v91('%s', -2))",
          $self->{name};
    } else {
      $sql = sprintf "SELECT sort_overflows FROM TABLE(snap_get_db('%s', -2))",
          $self->{name};
    }
    $self->{sort_overflows} = $self->{handle}->fetchrow_array($sql);
    $self->valdiff(\%params, qw(sort_overflows));
    $self->{sort_overflows_per_sec} = $self->{delta_sort_overflows} / $self->{delta_timestamp};
  } elsif ($params{mode} =~ /server::instance::database::sortoverflowpercentage/) {
    my $sql = undef;
    if ($self->version_is_minimum('9.1')) {
      $sql = sprintf "SELECT sort_overflows, total_sorts FROM TABLE(snap_get_db_v91('%s', -2))",
          $self->{name};
    } else {
      $sql = sprintf "SELECT sort_overflows, total_sorts FROM TABLE(snap_get_db('%s', -2))",
          $self->{name};
    }
    ($self->{sort_overflows}, $self->{total_sorts}) = $self->{handle}->fetchrow_array($sql);
    $self->valdiff(\%params, qw(sort_overflows total_sorts));
    $self->{sort_overflow_percentage} = $self->{delta_total_sorts} == 0 ? 0 :
        $self->{delta_sort_overflows} / $self->{delta_total_sorts};
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::database::listtablespaces/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{tablespaces}}) {
	printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::instance::database::tablespace/) {
      foreach (@{$self->{tablespaces}}) {
        # sind hier noch nach pctused sortiert
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::listbufferpools/) {
      foreach (sort { $a->{name} cmp $b->{name}; }  @{$self->{bufferpools}}) {
        printf "%s\n", $_->{name};
      }
      $self->add_nagios_ok("have fun");
    } elsif ($params{mode} =~ /server::instance::database::bufferpool/) {
      foreach (@{$self->{bufferpools}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::lock/) {
      foreach (@{$self->{locks}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::logutilization/) {
      foreach (@{$self->{partitions}}) {
        $_->nagios(%params);
        $self->merge_nagios($_);
      }
    } elsif ($params{mode} =~ /server::instance::database::usage/) {
      $self->add_nagios(
          $self->check_thresholds($self->{db_usage}, 80, 90),
          sprintf "database usage is %.2f%%",
              $self->{db_usage});
      $self->add_perfdata(sprintf "\'db_%s_usage\'=%.2f%%;%s;%s",
          lc $self->{name},
          $self->{db_usage},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::connectedusers/) {
      $self->add_nagios(
          $self->check_thresholds($self->{connected_users}, 50, 100),
          sprintf "%d connected users",
              $self->{connected_users});
      $self->add_perfdata(sprintf "connected_users=%d;%d;%d",
          $self->{connected_users},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::srp/) {
      $self->add_nagios(
          $self->check_thresholds($self->{srp}, '90:', '80:'),       
          sprintf "synchronous read percentage is %.2f%%", $self->{srp});
      $self->add_perfdata(sprintf "srp=%.2f%%;%s;%s",
          $self->{srp},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::awp/) {
      $self->add_nagios(
          $self->check_thresholds($self->{awp}, '90:', '80:'),       
          sprintf "asynchronous write percentage is %.2f%%", $self->{awp});
      $self->add_perfdata(sprintf "awp=%.2f%%;%s;%s",
          $self->{awp},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::indexusage/) {
      $self->add_nagios(
          $self->check_thresholds($self->{index_usage}, '98:', '90:'),       
          sprintf "index usage is %.2f%%", $self->{index_usage});
      $self->add_perfdata(sprintf "index_usage=%.2f%%;%s;%s",
          $self->{index_usage},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::lastbackup/) {
      $self->add_nagios(
          $self->check_thresholds($self->{last_backup}, '1', '2'),
          sprintf "last backup of db %s was %.2f days ago",
              $self->{name}, $self->{last_backup});
      $self->add_perfdata(sprintf "last_backup=%.2f;%s;%s",
          $self->{last_backup},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::staletablerunstats/) {
      # we only use warnings here
      $self->check_thresholds(0, 7, 99999);
      @{$self->{stale_tables}} = grep { $_->[1] >= $self->{warningrange} }
          @{$self->{stale_tables}};
      if (@{$self->{stale_tables}}) {
        $self->add_nagios_warning(sprintf '%d tables have outdated statistics', 
            scalar(@{$self->{stale_tables}}));
        foreach (@{$self->{stale_tables}}) {
          $self->add_nagios_warning(sprintf '%s:%.02f', $_->[0], $_->[1]);
        }
      } else {
        $self->add_nagios_ok('table statistics are up to date');
      }
    } elsif ($params{mode} =~ /server::instance::database::invalidobjects/) {
      # we only use warnings here
      $self->check_thresholds(0, 7, 99999);
      my $its_ok = 1;
      for my $obj (qw(triggers packages views routines tables)) {
        if (@{$self->{'invalid_'.$obj}}) {
          $its_ok = 0;
          $self->add_nagios_warning(sprintf '%d %s are invalid', 
              scalar(@{$self->{'invalid_'.$obj}}), $obj);
          foreach (@{$self->{'invalid_'.$obj}}) {
            $self->add_nagios_warning(sprintf '%s.%s', $_->[1], $_->[2]);
          }
        }
        $self->add_perfdata(sprintf "invalid_%s=%d", $obj, scalar(@{$self->{'invalid_'.$obj}}));
      }
      if ($its_ok) {
        $self->add_nagios_ok('no invalid objects found');
      }
    } elsif ($params{mode} =~ /server::instance::database::duppackages/) {
      if (@{$self->{duplicate_packages}}) {
        $self->add_nagios_warning(sprintf '%d duplicate pkgs:',
            scalar(@{$self->{duplicate_packages}}));
        foreach (@{$self->{duplicate_packages}}) {
          $self->add_nagios_warning(sprintf '%s(%dx)',
              $_->[0], $_->[1]);
        }
      } else {
        $self->add_nagios_ok('all package names are unique');
      }
      $self->add_perfdata(sprintf "dup_pkgs=%d", scalar(@{$self->{duplicate_packages}}));
    } elsif ($params{mode} =~ /server::instance::database::sortoverflows/) {
      printf STDERR "%s\n", Data::Dumper::Dumper($self->{sort_overflows_per_sec});
      $self->add_nagios(
          $self->check_thresholds($self->{sort_overflows_per_sec}, 0.01, 0.1),       
          sprintf "%.2f sort overflows per sec", $self->{sort_overflows_per_sec});
      $self->add_perfdata(sprintf "sort_overflows_per_sec=%.2f;%s;%s",
          $self->{sort_overflows_per_sec},
          $self->{warningrange}, $self->{criticalrange});
    } elsif ($params{mode} =~ /server::instance::database::sortoverflowpercentage/) {
      $self->add_nagios(
          $self->check_thresholds($self->{sort_overflow_percentage}, 5, 10),       
          sprintf "%.2f%% of all sorts used temporary disk space", $self->{sort_overflow_percentage});
      $self->add_perfdata(sprintf "sort_overflow_percentage=%.2f%%;%s;%s",
          $self->{sort_overflow_percentage},
          $self->{warningrange}, $self->{criticalrange});
    }
  }
}


1;
