# Copyright 2015 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets 
# the needs in IT infrastructure and application monitoring for 
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0  
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package centreon::vmware::cmdcpuhost;

use strict;
use warnings;
use centreon::vmware::common;

sub new {
    my $class = shift;
    my $self  = {};
    $self->{logger} = shift;
    $self->{commandName} = 'cpuhost';
    
    bless $self, $class;
    return $self;
}

sub getCommandName {
    my $self = shift;
    return $self->{commandName};
}

sub checkArgs {
    my ($self, %options) = @_;

    if (defined($options{arguments}->{esx_hostname}) && $options{arguments}->{esx_hostname} eq "") {
        $options{manager}->{output}->output_add(severity => 'UNKNOWN',
                                                short_msg => "Argument error: esx hostname cannot be null");
        return 1;
    }
    if (defined($options{arguments}->{disconnect_status}) && 
        $options{manager}->{output}->is_litteral_status(status => $options{arguments}->{disconnect_status}) == 0) {
        $options{manager}->{output}->output_add(severity => 'UNKNOWN',
                                                short_msg => "Argument error: wrong value for disconnect status '" . $options{arguments}->{disconnect_status} . "'");
        return 1;
    }
    if (($options{manager}->{perfdata}->threshold_validate(label => 'warning', value => $options{arguments}->{warning})) == 0) {
        $options{manager}->{output}->output_add(severity => 'UNKNOWN',
                                                short_msg => "Argument error: wrong value for warning value '" . $options{arguments}->{warning} . "'.");
        return 1;
    }
    if (($options{manager}->{perfdata}->threshold_validate(label => 'critical', value => $options{arguments}->{critical})) == 0) {
        $options{manager}->{output}->output_add(severity => 'UNKNOWN',
                                                short_msg => "Argument error: wrong value for critical value '" . $options{arguments}->{critical} . "'.");
        return 1;
    }
    return 0;
}

sub initArgs {
    my ($self, %options) = @_;
    
    foreach (keys %{$options{arguments}}) {
        $self->{$_} = $options{arguments}->{$_};
    }
    $self->{manager} = centreon::vmware::common::init_response();
    $self->{manager}->{output}->{plugin} = $options{arguments}->{identity};
    $self->{manager}->{perfdata}->threshold_validate(label => 'warning', value => $options{arguments}->{warning});
    $self->{manager}->{perfdata}->threshold_validate(label => 'critical', value => $options{arguments}->{critical});
}

sub set_connector {
    my ($self, %options) = @_;
    
    $self->{connector} = $options{connector};
}

sub run {
    my $self = shift;

    if (!($self->{connector}->{perfcounter_speriod} > 0)) {
        $self->{manager}->{output}->output_add(severity => 'UNKNOWN',
                                               short_msg => "Can't retrieve perf counters");
        return ;
    }

    my %filters = ();
    my $multiple = 0;
    if (defined($self->{esx_hostname}) && !defined($self->{filter})) {
        $filters{name} = qr/^\Q$self->{esx_hostname}\E$/;
    } elsif (!defined($self->{esx_hostname})) {
        $filters{name} = qr/.*/;
    } else {
        $filters{name} = qr/$self->{esx_hostname}/;
    }

    my @properties = ('name', 'runtime.connectionState', 'summary.hardware.numCpuCores', 'summary.hardware.cpuMhz');
    my $result = centreon::vmware::common::search_entities(command => $self, view_type => 'HostSystem', properties => \@properties, filter => \%filters);
    return if (!defined($result));

    if (scalar(@$result) > 1) {
        $multiple = 1;
    }
    my @instances = ('*');
    my $values = centreon::vmware::common::generic_performance_values_historic($self->{connector},
                            $result, 
                            [{'label' => 'cpu.usage.average',    'instances' => \@instances},
                             {'label' => 'cpu.usagemhz.average', 'instances' => \@instances}],
                            $self->{connector}->{perfcounter_speriod},
                            sampling_period => $self->{sampling_period}, time_shift => $self->{time_shift},
                            skip_undef_counter => 1, multiples => 1, multiples_result_by_entity => 1);
    return if (centreon::vmware::common::performance_errors($self->{connector}, $values) == 1);

    my $interval_min = centreon::vmware::common::get_interval_min(speriod => $self->{connector}->{perfcounter_speriod}, 
                                                                  sampling_period => $self->{sampling_period}, time_shift => $self->{time_shift});
    if ($multiple == 1) {
        $self->{manager}->{output}->output_add(severity => 'OK',
                                               short_msg => sprintf("All Total Average CPU usages are ok"));
    }
    foreach my $entity_view (@$result) {
        next if (centreon::vmware::common::host_state(connector => $self->{connector},
                                                    hostname => $entity_view->{name}, 
                                                    state => $entity_view->{'runtime.connectionState'}->val,
                                                    status => $self->{disconnect_status},
                                                    multiple => $multiple) == 0);
        my $entity_value = $entity_view->{mo_ref}->{value};
        my $total_cpu_average = centreon::vmware::common::simplify_number(centreon::vmware::common::convert_number($values->{$entity_value}->{$self->{connector}->{perfcounter_cache}->{'cpu.usage.average'}->{'key'} . ":"} * 0.01));
        my $total_cpu_mhz_average = centreon::vmware::common::simplify_number(centreon::vmware::common::convert_number($values->{$entity_value}->{$self->{connector}->{perfcounter_cache}->{'cpu.usagemhz.average'}->{'key'} . ":"}));
        
        my $exit = $self->{manager}->{perfdata}->threshold_check(value => $total_cpu_average, 
                                                                 threshold => [ { label => 'critical', exit_litteral => 'critical' }, { label => 'warning', exit_litteral => 'warning' } ]);
        
        $self->{manager}->{output}->output_add(long_msg => sprintf("'%s' Total Average CPU usage '%s%%' on last %s min", 
                                                                   $entity_view->{name}, $total_cpu_average, $interval_min));
        if ($multiple == 0 ||
            !$self->{manager}->{output}->is_status(value => $exit, compare => 'ok', litteral => 1)) {
            $self->{manager}->{output}->output_add(severity => $exit,
                                                   short_msg => sprintf("'%s' Total Average CPU usage '%s%%' on last %s min", 
                                                                        $entity_view->{name}, $total_cpu_average, $interval_min));
        }

        my $extra_label = '';
        $extra_label = '_' . $entity_view->{name} if ($multiple == 1);
        $self->{manager}->{output}->perfdata_add(label => 'cpu_total' . $extra_label, unit => '%',
                                                 value => $total_cpu_average,
                                                 warning => $self->{manager}->{perfdata}->get_perfdata_for_output(label => 'warning'),
                                                 critical => $self->{manager}->{perfdata}->get_perfdata_for_output(label => 'critical'),
                                                 min => 0, max => 100);
        $self->{manager}->{output}->perfdata_add(label => 'cpu_total_MHz' . $extra_label, unit => 'MHz',
                                                 value => $total_cpu_mhz_average,
                                                 min => 0, max => $entity_view->{'summary.hardware.numCpuCores'} * $entity_view->{'summary.hardware.cpuMhz'});

        foreach my $id (sort { my ($cida, $cia) = split /:/, $a;
                       my ($cidb, $cib) = split /:/, $b;
                                   $cia = -1 if (!defined($cia) || $cia eq "");
                                   $cib = -1 if (!defined($cib) || $cib eq "");
                       $cia <=> $cib} keys %{$values->{$entity_value}}) {
            my ($counter_id, $instance) = split /:/, $id;
            if ($instance ne "") {
                $self->{manager}->{output}->perfdata_add(label => 'cpu' . $instance . $extra_label, unit => '%',
                                                         value => centreon::vmware::common::simplify_number(centreon::vmware::common::convert_number($values->{$entity_value}->{$id}) * 0.01),
                                                         min => 0, max => 100);
            }
        }
    }
}

1;
