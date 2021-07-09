package DBD::DB2::Server::Instance::Database::Tablespace;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance::Database);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @tablespaces = ();
  my $initerrors = undef;

  sub add_tablespace {
    push(@tablespaces, shift);
  }

  sub return_tablespaces {
    return reverse 
        sort { $a->{name} cmp $b->{name} } @tablespaces;
  }
  
  sub init_tablespaces {
    my %params = @_;
    my $num_tablespaces = 0;
    if ($params{mode} =~ /server::instance::database::listtablespaces/) {
      my @tablespaceresult = $params{handle}->fetchall_array(q{
        SELECT tbspace, tbspacetype, datatype FROM syscat.tablespaces
      });
      foreach (@tablespaceresult) {
        my ($name, $type, $data) = @{$_};
        # A = All types of permanent data; regular table space 
        # L = All types of permanent data; large table space 
        # T = System temporary tables only 
        # U = Declared temporary tables only
        next if $params{notemp} && ($data eq "T" || $data eq "U");
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{type} = $type;
        my $tablespace = DBD::DB2::Server::Instance::Database::Tablespace->new(
            %thisparams);
        add_tablespace($tablespace);
        $num_tablespaces++;
      }
      if (! $num_tablespaces) {
        $initerrors = 1;
        return undef;
      }
    } elsif (($params{mode} =~ /server::instance::database::tablespace::usage/) ||
        ($params{mode} =~ /server::instance::database::tablespace::free/) ||
        ($params{mode} =~ /server::instance::database::tablespace::settings/) ||
        ($params{mode} =~ /server::instance::database::tablespace::remainingfreetime/)) {
      # evt snapcontainer statt container_utilization
      my @tablespaceresult = $params{handle}->fetchall_array(q{
        SELECT
            tbsp_name, tbsp_type, tbsp_state, tbsp_usable_size_kb,
            tbsp_total_size_kb, tbsp_used_size_kb, tbsp_free_size_kb,
            COALESCE(tbsp_using_auto_storage, 0),
            COALESCE(tbsp_auto_resize_enabled, 0),
            -- COALESCE(tbsp_increase_size,0), --bigint, conversion problems with dbd
            CASE WHEN tbsp_increase_size IS NULL OR tbsp_increase_size = 0 THEN 0 ELSE 1 END,
            COALESCE(tbsp_increase_size_percent, 0)
        FROM
            sysibmadm.tbsp_utilization
        WHERE
            tbsp_type = 'DMS'
        UNION ALL
        SELECT
            tu.tbsp_name, tu.tbsp_type, tu.tbsp_state, tu.tbsp_usable_size_kb,
            tu.tbsp_total_size_kb, tu.tbsp_used_size_kb,
            (cu.fs_total_size_kb - cu.fs_used_size_kb) AS tbsp_free_size_kb,
            0, 0, 0, 0
        FROM
            sysibmadm.tbsp_utilization tu
        INNER JOIN (
            SELECT
               tbsp_id,
               1 AS fs_total_size_kb,
               0 AS fs_used_size_kb
            FROM
                sysibmadm.container_utilization
            WHERE
                (fs_total_size_kb IS NULL OR fs_used_size_kb IS NULL)
            GROUP BY
                tbsp_id
        ) cu
        ON
            (tu.tbsp_type = 'SMS' AND tu.tbsp_id = cu.tbsp_id)
        UNION ALL
        SELECT
            tu.tbsp_name, tu.tbsp_type, tu.tbsp_state, tu.tbsp_usable_size_kb,
            tu.tbsp_total_size_kb, tu.tbsp_used_size_kb,
            (cu.fs_total_size_kb - cu.fs_used_size_kb) AS tbsp_free_size_kb,
            0, 0, 0, 0
        FROM
            sysibmadm.tbsp_utilization tu
        INNER JOIN (
            SELECT
               tbsp_id,
               SUM(fs_total_size_kb) AS fs_total_size_kb,
               SUM(fs_used_size_kb) AS fs_used_size_kb
            FROM
                sysibmadm.container_utilization
            WHERE
                (fs_total_size_kb IS NOT NULL AND fs_used_size_kb IS NOT NULL)
            GROUP BY
                tbsp_id
        ) cu
        ON
            (tu.tbsp_type = 'SMS' AND tu.tbsp_id = cu.tbsp_id)
      });
      foreach (@tablespaceresult) {
        my ($name, $type, $state, $total_size, $usable_size, $used_size, $free_size,
            $tbsp_using_auto_storage, $tbsp_auto_resize_enabled,
            $tbsp_increase_size, $tbsp_increase_size_percent) =
            @{$_};
        $type = $type =~ /^[dD]/ ? 'dms' : 'sms';
        next if ($params{mode} =~ /::dms::manual$/ && ($type ne 'dms' || $tbsp_using_auto_storage));
        next if ($params{mode} =~ /::dms$/ && ($type ne 'dms'));
        next if ($params{nosms} && ($type eq 'sms'));
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{type} = $type;
        $thisparams{state} = lc $state;
        $thisparams{total_size} = $total_size * 1024;
        $thisparams{usable_size} = $usable_size * 1024;
        $thisparams{used_size} = $used_size * 1024;
        $thisparams{free_size} = $free_size * 1024;
        $thisparams{tbsp_using_auto_storage} = $tbsp_using_auto_storage;
        $thisparams{tbsp_auto_resize_enabled} = $tbsp_auto_resize_enabled;
        $thisparams{tbsp_increase_size} = $tbsp_increase_size;
        $thisparams{tbsp_increase_size_percent} = $tbsp_increase_size_percent;
        my $tablespace = DBD::DB2::Server::Instance::Database::Tablespace->new(
            %thisparams);
        add_tablespace($tablespace);
        $num_tablespaces++;
      }
      if (! $num_tablespaces) {
        $initerrors = 1;
        return undef;
      }
    } elsif ($params{mode} =~ /server::instance::database::tablespace::datafile/) {
      my %thisparams = %params;
      $thisparams{name} = "dummy_for_datafiles";
      $thisparams{datafiles} = [];
      my $tablespace = DBD::DB2::Server::Instance::Database::Tablespace->new(
          %thisparams);
      add_tablespace($tablespace);
    }
  }
}

sub new {
  my $class = shift;
  my %params = @_;
  my $self = {
    handle => $params{handle},
    name => $params{name},
    type => $params{type},
    state => $params{state},
    total_size => $params{total_size},
    usable_size => $params{usable_size},
    used_size => $params{used_size},
    free_size => $params{free_size},
    tbsp_using_auto_storage => $params{tbsp_using_auto_storage},
    tbsp_auto_resize_enabled => $params{tbsp_auto_resize_enabled},
    tbsp_increase_size => $params{tbsp_increase_size},
    tbsp_increase_size_percent => $params{tbsp_increase_size_percent},
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
  if ($params{mode} =~ /server::instance::database::tablespace::settings::dms/) {
  } elsif ($params{mode} =~ /server::instance::database::tablespace::(usage|free)/) {
    if ($self->{type} eq 'sms') {
      # hier ist usable == used
      $self->{usable_size} = $self->{used_size} + $self->{free_size};
    }
    $self->{percent_used} =
        $self->{used_size} * 100 / $self->{usable_size};
    $self->{percent_free} = 100 - $self->{percent_used};
  } elsif ($params{mode} =~ /server::instance::database::tablespace::fragmentation/) {
  } elsif ($params{mode} =~ /server::instance::database::tablespace::datafile/) {
    DBD::DB2::Server::Instance::Database::Tablespace::Datafile::init_datafiles(%params);
    if (my @datafiles =
        DBD::DB2::Server::Instance::Database::Tablespace::Datafile::return_datafiles()) {
      $self->{datafiles} = \@datafiles;
    } else {
      $self->add_nagios_critical("unable to aquire datafile info");
    }
  } elsif ($params{mode} =~ /server::instance::database::tablespace::remainingfreetime/) {
    # load historical data
    # calculate slope, intercept (go back periods * interval)
    # calculate remaining time
    $self->{percent_used} = $self->{bytes_max} == 0 ?
        ($self->{bytes} - $self->{bytes_free}) / $self->{bytes} * 100 :
        ($self->{bytes} - $self->{bytes_free}) / $self->{bytes_max} * 100;
    $self->{usage_history} = $self->load_state( %params ) || [];
    my $now = time;
    if (scalar(@{$self->{usage_history}})) {
      $self->trace(sprintf "loaded %d data sets from     %s - %s", 
          scalar(@{$self->{usage_history}}),
          scalar localtime((@{$self->{usage_history}})[0]->[0]),
          scalar localtime($now));
      # only data sets with valid usage. only newer than 91 days
      $self->{usage_history} = 
          [ grep { defined $_->[1] && ($now - $_->[0]) < 7862400 } @{$self->{usage_history}} ];
      $self->trace(sprintf "trimmed to %d data sets from %s - %s", 
          scalar(@{$self->{usage_history}}),
          scalar localtime((@{$self->{usage_history}})[0]->[0]),
          scalar localtime($now));
    } else {
      $self->trace(sprintf "no historical data found");
    }
    push(@{$self->{usage_history}}, [ time, $self->{percent_used} ]);
    $params{save} = $self->{usage_history};
    $self->save_state(%params);
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::database::tablespace::settings::dms/) {
      if ($self->{tbsp_auto_resize_enabled} == 1) {
        if ($self->{tbsp_increase_size} == $self->{tbsp_increase_size_percent}) {
          if ($self->{tbsp_increase_size} == 0) {
            $self->add_nagios_critical(sprintf "tbs %s must set either tbsp_increase_size or tbsp_increase_size_percent",
              lc $self->{name});
          } else {
            $self->add_nagios_critical(sprintf "tbs %s has both tbsp_increase_size and tbsp_increase_size_percent set",
              lc $self->{name});
          }
        }
      }
      if (! $self->{nagios_level}) {
        $self->add_nagios_ok(sprintf "tbs %s settings are ok", lc $self->{name});
      }
    } elsif ($params{mode} =~ /server::instance::database::tablespace::usage/) {
      $self->add_nagios(
          $self->check_thresholds($self->{percent_used}, "90", "98"),
              sprintf("tbs %s usage is %.2f%%", $self->{name}, $self->{percent_used})
      );
      $self->add_perfdata(sprintf "\'tbs_%s_usage_pct\'=%.2f%%;%d;%d",
          lc $self->{name},
          $self->{percent_used},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "\'tbs_%s_usage\'=%dMB;%d;%d;%d;%d",
          lc $self->{name},
          $self->{used_size} / 1048576,
          $self->{warningrange} * $self->{usable_size} / 100 / 1048576,
          $self->{criticalrange} * $self->{usable_size} / 100 / 1048576,
          0, $self->{usable_size} / 1048576);
    } elsif ($params{mode} =~ /server::instance::database::tablespace::free/) {
      # umrechnen der thresholds
      # ()/%
      # MB
      # GB
      # KB
      if (($self->{warningrange} && $self->{warningrange} !~ /^\d+:/) ||
          ($self->{criticalrange} && $self->{criticalrange} !~ /^\d+:/)) {
        $self->add_nagios_unknown("you want an alert if free space is _above_ a threshold????");
        return;
      }
      if (! $params{units}) {
        $params{units} = "%";
      }
      $self->{warning_bytes} = 0;
      $self->{critical_bytes} = 0;
      if ($params{units} eq "%") {
        $self->add_nagios(
            $self->check_thresholds($self->{percent_free}, "5:", "2:"),
                sprintf("tbs %s has %.2f%% free space left", $self->{name}, $self->{percent_free})
        );
        $self->{warningrange} =~ s/://g;
        $self->{criticalrange} =~ s/://g;
        $self->add_perfdata(sprintf "\'tbs_%s_free_pct\'=%.2f%%;%d:;%d:",
            lc $self->{name},
            $self->{percent_free},
            $self->{warningrange}, $self->{criticalrange});
        $self->add_perfdata(sprintf "\'tbs_%s_free\'=%dMB;%.2f:;%.2f:;0;%.2f",
            lc $self->{name},
            $self->{free_size} / 1048576,
            $self->{warningrange} * $self->{usable_size} / 100 / 1048576,
            $self->{criticalrange} * $self->{usable_size} / 100 / 1048576,
            $self->{usable_size} / 1048576);
      } else {
        my $factor = 1024 * 1024; # default MB
        if ($params{units} eq "GB") {
          $factor = 1024 * 1024 * 1024;
        } elsif ($params{units} eq "MB") {
          $factor = 1024 * 1024;
        } elsif ($params{units} eq "KB") {
          $factor = 1024;
        }
        $self->{warningrange} ||= "5:";
        $self->{criticalrange} ||= "2:";
        my $saved_warningrange = $self->{warningrange};
        my $saved_criticalrange = $self->{criticalrange};
        # : entfernen weil gerechnet werden muss
        $self->{warningrange} =~ s/://g;
        $self->{criticalrange} =~ s/://g;
        $self->{warningrange} = $self->{warningrange} ?
            $self->{warningrange} * $factor : 5 * $factor;
        $self->{criticalrange} = $self->{criticalrange} ?
            $self->{criticalrange} * $factor : 2 * $factor;
        $self->{percent_warning} = 100 * $self->{warningrange} / $self->{usable_size};
        $self->{percent_critical} = 100 * $self->{criticalrange} / $self->{usable_size};
        $self->{warningrange} .= ':';
        $self->{criticalrange} .= ':';
        $self->add_nagios(
            $self->check_thresholds($self->{free_size}, "5242880:", "1048576:"),
                sprintf("tbs %s has %.2f%s free space left", $self->{name},
                    $self->{free_size} / $factor, $params{units})
        );
	$self->{warningrange} = $saved_warningrange;
        $self->{criticalrange} = $saved_criticalrange;
        $self->{warningrange} =~ s/://g;
        $self->{criticalrange} =~ s/://g;
        $self->add_perfdata(sprintf "\'tbs_%s_free_pct\'=%.2f%%;%.2f:;%.2f:",
            lc $self->{name},
            $self->{percent_free}, $self->{percent_warning}, 
            $self->{percent_critical});
        $self->add_perfdata(sprintf "\'tbs_%s_free\'=%.2f%s;%.2f:;%.2f:;0;%.2f",
            lc $self->{name},
            $self->{free_size} / $factor, $params{units},
            $self->{warningrange},
            $self->{criticalrange},
            $self->{usable_size} / $factor);
      }
    }
  }
}

# CREATE  REGULAR  TABLESPACE USERSPACE2 PAGESIZE 4 K  MANAGED BY SYSTEM  USING ('/home/db2inst1/db2inst1/NODE0000/TOOLSDB/T0000008', '/opt/ibm/TOOLSDB' ) EXTENTSIZE 16 OVERHEAD 12.67 PREFETCHSIZE 16 TRANSFERRATE 0.18 BUFFERPOOL  IBMDEFAULTBP  DROPPED TABLE RECOVERY OFF
