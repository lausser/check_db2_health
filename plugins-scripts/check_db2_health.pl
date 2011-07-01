
package main;

use strict;
use Getopt::Long qw(:config no_ignore_case);
use File::Basename;
use lib dirname($0);
use Nagios::DBD::DB2::Server;

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

use vars qw ($PROGNAME $REVISION $CONTACT $TIMEOUT $STATEFILESDIR $needs_restart %commandline);

$PROGNAME = "check_db2_health";
$REVISION = '$Revision: #PACKAGE_VERSION# $';
$CONTACT = 'gerhard.lausser@consol.de';
$TIMEOUT = 60;
$STATEFILESDIR = '#STATEFILES_DIR#';
$needs_restart = 0;

my @modes = (
  ['server::connectiontime',
      'connection-time', undef,
      'Time to connect to the database' ],
  ['server::instance::database::connectedusers',
      'connected-users', undef,
      'Number of currently connected users' ],
  ['server::sql',
      'sql', undef,
      'any sql command returning a single number' ],
  ['server::instance::database::usage',
      'database-usage', undef,
      'Used space at the database level' ],
  ['server::instance::database::srp',
      'synchronous-read-percentage', undef,
      'Percentage of synchronous reads' ],
  ['server::instance::database::awp',
      'asynchronous-write-percentage', undef,
      'Percentage of asynchronous writes' ],
  ['server::instance::database::tablespace::usage',
      'tablespace-usage', undef,
      'Used space at the tablespace level' ],
  ['server::instance::database::tablespace::free',
      'tablespace-free', undef,
      'Free space at the tablespace level' ],
  ['server::instance::database::bufferpool::hitratio',
      'bufferpool-hitratio', undef,
      'Hit ratio of a buffer pool' ],
  ['server::instance::database::bufferpool::hitratiodata',
      'bufferpool-data-hitratio', undef,
      'Hit ratio of a buffer pool (data pages only)' ],
  ['server::instance::database::bufferpool::hitratioindex',
      'bufferpool-index-hitratio', undef,
      'Hit ratio of a buffer pool (indexes only)' ],
  ['server::instance::database::indexusage',
      'index-usage', undef,
      'Percentage of selects that use an index' ],
  ['server::instance::database::staletablerunstats',
      'stale-table-runstats', undef,
      'Tables whose statistics haven\'t been updated for a while' ],
  ['server::instance::database::lock::deadlocks',
      'deadlocks', undef,
      'Number of deadlocks per second' ],
  ['server::instance::database::lock::lockwaits',
      'lock-waits', undef,
      'Number of lock waits per second' ],
  ['server::instance::database::lock::lockwaiting',
      'lock-waiting', undef,
      'Percentage of the time locks spend waiting' ],
  ['server::instance::database::sortoverflows',
      'sort-overflows', undef,
      'Number of sort overflows per second (Sorts needing temporary tables on disk)' ],
  ['server::instance::database::sortoverflowpercentage',
      'sort-overflow-percentage', undef,
      'Percentage of sorts which result in an overflow' ],
  ['server::instance::database::logutilization',
      'log-utilization', undef,
      'Log utilization for a database' ],
  ['server::instance::database::lastbackup',
      'last-backup', undef,
      'Time (in days) since the database was last backupped' ],
  ['server::instance::listdatabases',
      'list-databases', undef,
      'convenience function which lists all databases' ],
  ['server::instance::database::listtablespaces',
      'list-tablespaces', undef,
      'convenience function which lists all tablespaces' ],
  ['server::instance::database::listbufferpools',
      'list-bufferpools', undef,
      'convenience function which lists all buffer pools' ],
  #  health SELECT * FROM TABLE(HEALTH_DB_HI('',-1)) AS T
);

sub print_usage () {
  print <<EOUS;
  Usage:
    $PROGNAME [-v] [-t <timeout>] --hostname <dbhost> --port <dbport,def: 50000>
        --username=<username> --password=<password> --mode=<mode>
        --database=<database>
    $PROGNAME [-h | --help]
    $PROGNAME [-V | --version]

  Options:
    --connect
       the connect string
    --username
       the db2 user
    --password
       the db2 user's password
    --database
       the database you want to check
    --warning
       the warning range
    --critical
       the critical range
    --mode
       the mode of the plugin. select one of the following keywords:
EOUS
  my $longest = length ((reverse sort {length $a <=> length $b} map { $_->[1] } @modes)[0]);
  my $format = "       %-".
  (length ((reverse sort {length $a <=> length $b} map { $_->[1] } @modes)[0])).
  "s\t(%s)\n";
  foreach (@modes) {
    printf $format, $_->[1], $_->[3];
  }
  printf "\n";
  print <<EOUS;
    --name
       the name of the tablespace, datafile, wait event, 
       latch, enqueue, or sql statement depending on the mode.
    --name2
       if name is a sql statement, this statement would appear in
       the output and the performance data. This can be ugly, so 
       name2 can be used to appear instead.
    --regexp
       if this parameter is used, name will be interpreted as a 
       regular expression.
    --units
       one of %, KB, MB, GB. This is used for a better output of mode=sql
       and for specifying thresholds for mode=tablespace-free

  Tablespace-related modes check all tablespaces in one run by default.
  If only a single tablespace should be checked, use the --name parameter.
  The same applies to databuffercache-related modes.

  In mode sql you can url-encode the statement so you will not have to mess
  around with special characters in your Nagios service definitions.
  Instead of 
  --name="select count(*) from v\$session where status = 'ACTIVE'"
  you can say 
  --name=select%20count%28%2A%29%20from%20v%24session%20where%20status%20%3D%20%27ACTIVE%27
  For your convenience you can call check_db2_health with the --encode
  option and it will encode the standard input.

EOUS
  
}

sub print_help () {
  print "Copyright (c) Gerhard Lausser\n\n";
  print "\n";
  print "  Check various parameters of DB2 databases \n";
  print "\n";
  print_usage();
  support();
}


sub print_revision ($$) {
  my $commandName = shift;
  my $pluginRevision = shift;
  $pluginRevision =~ s/^\$Revision: //;
  $pluginRevision =~ s/ \$\s*$//;
  print "$commandName ($pluginRevision)\n";
  print "This nagios plugin comes with ABSOLUTELY NO WARRANTY. You may redistribute\ncopies of this plugin under the terms of the GNU General Public License.\n";
}

sub support () {
  my $support='Send email to gerhard.lausser@consol.de if you have questions\nregarding use of this software. \nPlease include version information with all correspondence (when possible,\nuse output from the --version option of the plugin itself).\n';
  $support =~ s/@/\@/g;
  $support =~ s/\\n/\n/g;
  print $support;
}

sub contact_author ($$) {
  my $item = shift;
  my $strangepattern = shift;
  if ($commandline{verbose}) {
    printf STDERR
        "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n".
        "You found a line which is not recognized by %s\n".
        "This means, certain components of your system cannot be checked.\n".
        "Please contact the author %s and\nsend him the following output:\n\n".
        "%s /%s/\n\nThank you!\n".
        "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++\n",
            $PROGNAME, $CONTACT, $item, $strangepattern;
  }
}

%commandline = ();
my @params = (
    "timeout|t=i",
    "version|V",
    "help|h",
    "verbose|v",
    "debug|d",
    "hostname=s",
    "username=s",
    "password=s",
    "port=i",
    "mode|m=s",
    "database=s",
    "tablespace=s",
    "datafile=s",
    "waitevent=s",
    "name=s",
    "name2=s",
    "regexp",
    "perfdata",
    "warning=s",
    "critical=s",
    "dbthresholds:s",
    "absolute|a",
    "basis",
    "lookback|l=i",
    "environment|e=s%",
    "method=s",
    "runas|r=s",
    "scream",
    "shell",
    "eyecandy",
    "encode",
    "units=s",
    "3",
    "statefilesdir=s",
    "with-mymodules-dyn-dir=s",
    "report=s",
    "extra-opts:s");

if (! GetOptions(\%commandline, @params)) {
  print_help();
  exit $ERRORS{UNKNOWN};
}

if (exists $commandline{'extra-opts'}) {
  # read the extra file and overwrite other parameters
  my $extras = Extraopts->new(file => $commandline{'extra-opts'}, commandline => \%commandline);
  if (! $extras->is_valid()) {
    printf "extra-opts are not valid: %s\n", $extras->{errors};
    exit $ERRORS{UNKNOWN};
  } else {
    $extras->overwrite();
  }
}

if (exists $commandline{version}) {
  print_revision($PROGNAME, $REVISION);
  exit $ERRORS{OK};
}

if (exists $commandline{help}) {
  print_help();
  exit $ERRORS{OK};
} elsif (! exists $commandline{mode}) {
  printf "Please select a mode\n";
  print_help();
  exit $ERRORS{OK};
}

if ($commandline{mode} eq "encode") {
  my $input = <>;
  chomp $input;
  $input =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
  printf "%s\n", $input;
  exit $ERRORS{OK};
}

if (exists $commandline{3}) {
  $ENV{NRPE_MULTILINESUPPORT} = 1;
}

if (exists $commandline{timeout}) {
  $TIMEOUT = $commandline{timeout};
}

if (exists $commandline{verbose}) {
  $DBD::DB2::Server::verbose = exists $commandline{verbose};
}

if (exists $commandline{scream}) {
#  $DBD::DB2::Server::hysterical = exists $commandline{scream};
}

if (exists $commandline{method}) {
  # dbi, snmp or sqlplus
} else {
  $commandline{method} = "dbi";
}

if (exists $commandline{report}) {
  # short, long, html
} else {
  $commandline{report} = "long";
}

if (exists $commandline{'with-mymodules-dyn-dir'}) {
  $DBD::DB2::Server::my_modules_dyn_dir = $commandline{'with-mymodules-dyn-dir'};
} else {
  $DBD::DB2::Server::my_modules_dyn_dir = '#MYMODULES_DYN_DIR#';
}

if (exists $commandline{environment}) {
  # if the desired environment variable values are different from
  # the environment of this running script, then a restart is necessary.
  # because setting $ENV does _not_ change the environment of the running script.
  foreach (keys %{$commandline{environment}}) {
    if ((! $ENV{$_}) || ($ENV{$_} ne $commandline{environment}->{$_})) {
      $needs_restart = 1;
      $ENV{$_} = $commandline{environment}->{$_};
      printf STDERR "new %s=%s forces restart\n", $_, $ENV{$_} 
          if $DBD::DB2::Server::verbose;
    }
  }
  # e.g. called with --runas dbnagio. shlib_path environment variable is stripped
  # during the sudo.
  # so the perl interpreter starts without a shlib_path. but --runas cares for
  # a --environment shlib_path=...
  # so setting the environment variable in the code above and restarting the 
  # perl interpreter will help it find shared libs
}

if (exists $commandline{runas}) {
  # remove the runas parameter
  # exec sudo $0 ... the remaining parameters
  $needs_restart = 1;
  # if the calling script has a path for shared libs and there is no --environment
  # parameter then the called script surely needs the variable too.
  foreach my $important_env qw(LD_LIBRARY_PATH SHLIB_PATH 
      DB2_HOME) {
    if ($ENV{$important_env} && ! scalar(grep { /^$important_env=/ } 
        keys %{$commandline{environment}})) {
      $commandline{environment}->{$important_env} = $ENV{$important_env};
      printf STDERR "add important --environment %s=%s\n", 
          $important_env, $ENV{$important_env} if $DBD::DB2::Server::verbose;
    }
  }
}

if ($needs_restart) {
  my @newargv = ();
  my $runas = undef;
  if (exists $commandline{runas}) {
    $runas = $commandline{runas};
    delete $commandline{runas};
  }
  foreach my $option (keys %commandline) {
    if (grep { /^$option/ && /=/ } @params) {
      if (ref ($commandline{$option}) eq "HASH") {
        foreach (keys %{$commandline{$option}}) {
          push(@newargv, sprintf "--%s", $option);
          push(@newargv, sprintf "%s=%s", $_, $commandline{$option}->{$_});
        }
      } else {
        push(@newargv, sprintf "--%s", $option);
        push(@newargv, sprintf "%s", $commandline{$option});
      }
    } else {
      push(@newargv, sprintf "--%s", $option);
    }
  }
  if ($runas && ($> == 0)) {
    # this was not my idea. some people connect as root to their nagios clients.
    exec "su", "-c", sprintf("%s %s", $0, join(" ", @newargv)), "-", $runas;
  } elsif ($runas) {
    exec "sudo", "-S", "-u", $runas, $0, @newargv;
  } else {
    exec $0, @newargv;  
    # this makes sure that even a SHLIB or LD_LIBRARY_PATH are set correctly
    # when the perl interpreter starts. Setting them during runtime does not
    # help loading e.g. libclntsh.so
  }
  exit;
}

if (exists $commandline{shell}) {
  # forget what you see here.
  system("/bin/sh");
}

if (! exists $commandline{statefilesdir}) {
  if (exists $ENV{OMD_ROOT}) {
    $commandline{statefilesdir} = $ENV{OMD_ROOT}."/var/tmp/check_db2_health";
  } else {
    $commandline{statefilesdir} = $STATEFILESDIR;
  }
}

if (exists $commandline{name}) {
  # objects can be encoded like an url
  # with s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;
  if (($commandline{mode} ne "sql") || 
      (($commandline{mode} eq "sql") &&
       ($commandline{name} =~ /select%20/i))) { # protect ... like '%cac%' ... from decoding
    $commandline{name} =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
  }
  if ($commandline{name} =~ /^0$/) {
    # without this, $params{selectname} would be treated like undef
    $commandline{name} = "00";
  } 
}

$SIG{'ALRM'} = sub {
  printf "UNKNOWN - %s timed out after %d seconds\n", $PROGNAME, $TIMEOUT;
  exit $ERRORS{UNKNOWN};
};
alarm($TIMEOUT);

my $nagios_level = $ERRORS{UNKNOWN};
my $nagios_message = "";
my $perfdata = "";
my $racmode = 0;
if ($commandline{mode} =~ /^rac-([^\-.]+)/) {
  $racmode = 1;
  $commandline{mode} =~ s/^rac\-//g;
}
if ($commandline{mode} =~ /^my-([^\-.]+)/) {
  my $param = $commandline{mode};
  $param =~ s/\-/::/g;
  push(@modes, [$param, $commandline{mode}, undef, 'my extension']);
} elsif ((! grep { $commandline{mode} eq $_ } map { $_->[1] } @modes) &&
    (! grep { $commandline{mode} eq $_ } map { defined $_->[2] ? @{$_->[2]} : () } @modes)) {
  printf "UNKNOWN - mode %s\n", $commandline{mode};
  print_usage();
  exit 3;
}

my %params = (
    timeout => $TIMEOUT,
    mode => (
        map { $_->[0] } 
        grep {
           ($commandline{mode} eq $_->[1]) || 
           ( defined $_->[2] && grep { $commandline{mode} eq $_ } @{$_->[2]}) 
        } @modes
    )[0],
    cmdlinemode => $commandline{mode},
    method => ($commandline{method} ||
        $ENV{NAGIOS__SERVICEDB2_METH} ||
        $ENV{NAGIOS__HOSTDB2_METH} || 'dbi'),
    hostname => ($commandline{hostname}  || 
        $ENV{NAGIOS__SERVICEDB2_HOST} ||
        $ENV{NAGIOS__HOSTDB2_HOST}),
    username => ($commandline{username} || 
        $ENV{NAGIOS__SERVICEDB2_USER} ||
        $ENV{NAGIOS__HOSTDB2_USER}),
    password => ($commandline{password} || 
        $ENV{NAGIOS__SERVICEDB2_PASS} ||
        $ENV{NAGIOS__HOSTDB2_PASS}),
    port => ($commandline{port} || 
        $ENV{NAGIOS__SERVICEDB2_PORT} ||
        $ENV{NAGIOS__HOSTDB2_PORT}),
    database => ($commandline{database} || 
        $ENV{NAGIOS__SERVICEDB2_DATABASE} ||
        $ENV{NAGIOS__HOSTDB2_DATABASE}),
    warningrange => $commandline{warning},
    criticalrange => $commandline{critical},
    dbthresholds => $commandline{dbthresholds},
    absolute => $commandline{absolute},
    lookback => $commandline{lookback},
    tablespace => $commandline{tablespace},
    datafile => $commandline{datafile},
    basis => $commandline{basis},
    selectname => $commandline{name} || $commandline{tablespace} || $commandline{datafile},
    regexp => $commandline{regexp},
    name => $commandline{name},
    name2 => $commandline{name2} || $commandline{name},
    units => $commandline{units},
    eyecandy => $commandline{eyecandy},
    statefilesdir => $commandline{statefilesdir},
    verbose => $commandline{verbose},
    report => $commandline{report},
);
my $server = undef;

$server = DBD::DB2::Server->new(%params);
$server->nagios(%params);
$server->calculate_result();
$nagios_message = $server->{nagios_message};
$nagios_level = $server->{nagios_level};
$perfdata = $server->{perfdata};

printf "%s - %s", $ERRORCODES{$nagios_level}, $nagios_message;
printf " | %s", $perfdata if $perfdata;
printf "\n";
exit $nagios_level;
