package DBD::DB2::Server::Instance::Database::Bufferpool;

use strict;

our @ISA = qw(DBD::DB2::Server::Instance::Database);

my %ERRORS=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
my %ERRORCODES=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

{
  my @bufferpools = ();
  my $initerrors = undef;

  sub add_bufferpool {
    push(@bufferpools, shift);
  }

  sub return_bufferpools {
    return reverse 
        sort { $a->{name} cmp $b->{name} } @bufferpools;
  }
  
  sub init_bufferpools {
    my %params = @_;
    my $num_bufferpools = 0;
    if ($params{mode} =~ /server::instance::database::listbufferpools/) {
      my @bufferpoolresult = $params{handle}->fetchall_array(q{
        SELECT bpname FROM syscat.bufferpools
      });
      foreach (@bufferpoolresult) {
        my ($name, $type) = @{$_};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        my $bufferpool = DBD::DB2::Server::Instance::Database::Bufferpool->new(
            %thisparams);
        add_bufferpool($bufferpool);
        $num_bufferpools++;
      }
      if (! $num_bufferpools) {
        $initerrors = 1;
        return undef;
      }
    } elsif ($params{mode} =~ /server::instance::database::bufferpool::hitratio/) {
      my $sql = q{
        SELECT 
          bp_name,
          pool_data_p_reads, pool_index_p_reads,
          pool_data_l_reads, pool_index_l_reads
        FROM 
          TABLE( snapshot_bp( 'THISDATABASE', -1 ))
        AS 
          snap
        INNER JOIN
          syscat.bufferpools sbp
        ON
          sbp.bpname = snap.bp_name
      };
      $sql =~ s/THISDATABASE/$params{database}/g;
      my @bufferpoolresult = $params{handle}->fetchall_array($sql);
      foreach (@bufferpoolresult) {
        my ($name, $pool_data_p_reads, $pool_index_p_reads,
            $pool_data_l_reads, $pool_index_l_reads) = @{$_};
        if ($params{regexp}) {
          next if $params{selectname} && $name !~ /$params{selectname}/;
        } else {
          next if $params{selectname} && lc $params{selectname} ne lc $name;
        }
        my %thisparams = %params;
        $thisparams{name} = $name;
        $thisparams{pool_data_p_reads} = $pool_data_p_reads;
        $thisparams{pool_index_p_reads} = $pool_index_p_reads;
        $thisparams{pool_data_l_reads} = $pool_data_l_reads;
        $thisparams{pool_index_l_reads} = $pool_index_l_reads;
        my $bufferpool = DBD::DB2::Server::Instance::Database::Bufferpool->new(
            %thisparams);
        add_bufferpool($bufferpool);
        $num_bufferpools++;
      }
      if (! $num_bufferpools) {
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
    pool_data_p_reads => $params{pool_data_p_reads},
    pool_index_p_reads => $params{pool_index_p_reads},
    pool_data_l_reads => $params{pool_data_l_reads},
    pool_index_l_reads => $params{pool_index_l_reads},
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
  if ($params{mode} =~ /server::instance::database::bufferpool::hitratiodata/) {
    $self->valdiff(\%params, qw(pool_data_l_reads pool_data_p_reads));
    $self->{hitratio} = 
        ($self->{pool_data_l_reads} > 0) ?
        (1 - ($self->{pool_data_p_reads} / $self->{pool_data_l_reads})) * 100
        : 100;
    $self->{hitratio_now} = 
        ($self->{delta_pool_data_l_reads} > 0) ?
        (1 - ($self->{delta_pool_data_p_reads} / $self->{delta_pool_data_l_reads})) * 100
        : 100;
  } elsif ($params{mode} =~ /server::instance::database::bufferpool::hitratioindex/) {
    $self->valdiff(\%params, qw(pool_index_l_reads pool_index_p_reads));
    $self->{hitratio} = 
        ($self->{pool_index_l_reads} > 0) ?
        (1 - ($self->{pool_index_p_reads} / $self->{pool_index_l_reads})) * 100
        : 100;
    $self->{hitratio_now} = 
        ($self->{delta_pool_index_l_reads} > 0) ?
        (1 - ($self->{delta_pool_index_p_reads} / $self->{delta_pool_index_l_reads})) * 100
        : 100;
  } elsif ($params{mode} =~ /server::instance::database::bufferpool::hitratio/) {
    $self->valdiff(\%params, qw(pool_data_l_reads pool_index_l_reads
        pool_data_p_reads pool_index_p_reads));
    $self->{hitratio} = 
        ($self->{pool_data_l_reads} + $self->{pool_index_l_reads}) > 0 ?
        (1 - (($self->{pool_data_p_reads} + $self->{pool_index_p_reads}) /
        ($self->{pool_data_l_reads} + $self->{pool_index_l_reads}))) * 100
        : 100;
    $self->{hitratio_now} = 
        ($self->{delta_pool_data_l_reads} + $self->{delta_pool_index_l_reads}) > 0 ?
        (1 - (($self->{delta_pool_data_p_reads} + $self->{delta_pool_index_p_reads}) /
        ($self->{delta_pool_data_l_reads} + $self->{delta_pool_index_l_reads}))) * 100 
        : 100;
  }
}

sub nagios {
  my $self = shift;
  my %params = @_;
  if (! $self->{nagios_level}) {
    if ($params{mode} =~ /server::instance::database::bufferpool::hitratio(.*)/) {
      my $refkey = 'hitratio'.($params{lookback} ? '_now' : '');
      $self->add_nagios(
          $self->check_thresholds($self->{$refkey}, "98:", "90:"),
              sprintf("bufferpool %s %shitratio is %.2f%%", 
              $self->{name},
              ($1 ? (($1 eq 'data') ? 'data page ' : 'index ') : ''),
              $self->{$refkey})
      );
      $self->add_perfdata(sprintf "\'bp_%s_hitratio\'=%.2f%%;%s;%s",
          lc $self->{name},
          $self->{hitratio},
          $self->{warningrange}, $self->{criticalrange});
      $self->add_perfdata(sprintf "\'bp_%s_hitratio_now\'=%.2f%%",
          lc $self->{name},
          $self->{hitratio_now});
    }
  }
}


