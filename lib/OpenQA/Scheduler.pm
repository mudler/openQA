# Copyright (C) 2015 SUSE Linux GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Scheduler;

use strict;
use warnings;
use base qw/Net::DBus::Object/;
use Net::DBus::Exporter qw/org.opensuse.openqa.Scheduler/;
use Net::DBus::Reactor;
use Data::Dump qw/pp/;

use OpenQA::IPC;
use OpenQA::Scheduler::Scheduler qw//;
use OpenQA::Scheduler::Locks qw//;

sub run {
    OpenQA::Scheduler->new();
    Net::DBus::Reactor->main->run;
}

sub new {
    my ($class) = @_;
    $class = ref $class || $class;
    # register @ IPC - we use DBus reactor here for symplicity
    my $ipc = OpenQA::IPC->ipc;
    return unless $ipc;
    my $service = $ipc->register_service('scheduler');
    my $self = $class->SUPER::new($service, '/Scheduler');
    $self->{ipc} = $ipc;
    bless $self, $class;

    return $self;
}

# Scheduler ABI goes here
## Assets
dbus_method('asset_delete', [['dict', 'string', 'string']], ['uint16']);
sub asset_delete {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_delete(%$args);
    return $rs;
}

dbus_method('asset_get', [['dict', 'string', 'string']], [['dict', 'string', 'string']]);
sub asset_get {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_get(%$args);
    return {} unless $rs;
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    return $rs->first;
}

dbus_method('asset_list', [['dict', 'string', 'string']], [['array', ['dict', 'string', 'string']]]);
sub asset_list {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_list(%$args);
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    return [$rs->all];
}

dbus_method('asset_register', [['dict', 'string', 'string']], [['dict', 'string', 'string']]);
sub asset_register {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::asset_register(%$args);
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    return $rs->first;
}

## Worker commands
dbus_method('command_enqueue', [['dict', 'string', 'string']], ['bool']);
sub command_enqueue {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::command_enqueue(%$args);
}

# this is here for legacy reasons, command_enqueue is the command_enqueue_checked
dbus_method('command_enqueue_checked', [['dict', 'string', 'uint16']], ['bool']);
sub command_enqueue_checked {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::command_enqueue(%$args);
}

## Jobs
dbus_method('job_cancel', ['uint16', 'bool'], ['uint16']);
sub job_cancel {
    my ($self, $jobid, $newbuild) = @_;
    return OpenQA::Scheduler::Scheduler::job_cancel($jobid, $newbuild);
}

dbus_method('job_cancel_by_iso', ['string', 'bool'], ['uint16']);
sub job_cancel_by_iso {
    my ($self, $iso, $newbuild) = @_;
    return OpenQA::Scheduler::Scheduler::job_cancel($iso, $newbuild);
}

dbus_method('job_cancel_by_settings', [['dict', 'string', 'string'], 'bool'], ['uint16']);
sub job_cancel_by_settings {
    my ($self, $settings, $newbuild) = @_;
    return OpenQA::Scheduler::Scheduler::job_cancel($settings, $newbuild);
}

dbus_method('job_create', [['dict', 'string', ['variant']], 'bool'], [['dict', 'string', ['variant']]]);
sub job_create {
    my ($self, @args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::job_create(@args);
    return $rs->to_hash(assets => 1);
}

dbus_method('job_delete', ['uint16'], ['uint16']);
sub job_delete {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_delete($args);
}

dbus_method('job_delete_by_iso', ['string'], ['uint16']);
sub job_delete_by_iso {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_delete($args);
}

dbus_method('job_duplicate', [['dict', 'string', 'string']], ['uint16']);
sub job_duplicate {
    my ($self, $args) = @_;
    my $res = OpenQA::Scheduler::Scheduler::job_duplicate(%$args);
    return 0 unless $res;
    return $res;
}

dbus_method('job_get', ['uint16'], [['dict', 'string', ['variant']]]);
sub job_get {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_get($args);
}

dbus_method('job_grab', [['dict', 'string', ['variant']]], [['dict', 'string', ['variant']]]);
sub job_grab {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_grab(%$args);
}

dbus_method('job_notify_workers');
sub job_notify_workers {
    my ($self) = @_;
    OpenQA::Scheduler::Scheduler::job_notify_workers;
}

dbus_method('job_restart', [['array', 'uint16']], [['array', 'uint16']]);
sub job_restart {
    my ($self, $args) = @_;
    my @res = OpenQA::Scheduler::Scheduler::job_restart($args);
    return \@res;
}

dbus_method('job_set_done', [['dict', 'string', 'string']], ['uint16']);
sub job_set_done {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_set_done(%$args);
}

dbus_method('jobs_get_dead_worker', ['string'], [['array', ['dict', 'string', ['variant']]]]);
sub jobs_get_dead_worker {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::jobs_get_dead_worker($args);
}

dbus_method('job_update_result', [['dict', 'string', ['variant']]], ['uint16']);
sub job_update_result {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_update_result(%$args);
}

dbus_method('job_update_status', ['uint16', ['dict', 'string', ['variant']]], ['uint16']);
sub job_update_status {
    my ($self, $jobid, $status) = @_;
}

dbus_method('query_jobs', [['dict', 'string', 'string']], [['array', ['dict', 'string', ['variant']]]]);
sub query_jobs {
    my ($self, $args) = @_;
    my $rs = OpenQA::Scheduler::Scheduler::query_jobs(%$args);
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    return [$rs->all];
}

dbus_method('job_set_waiting', ['uint16'], ['uint16']);
sub job_set_waiting {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_set_waiting($args);
}

dbus_method('job_set_running', ['uint16'], ['uint16']);
sub job_set_running {
    my ($self, $args) = @_;
    return OpenQA::Scheduler::Scheduler::job_set_running($args);
}

## Worker auth
dbus_method('validate_workerid', ['uint16'], ['bool']);
sub validate_workerid {
    my ($self, $args) = @_;
    my $res = OpenQA::Scheduler::Scheduler::_validate_workerid($args);
    return 1 if ($res);
    return 0;
}

## Lock API
dbus_method('mutex_create', ['string', 'uint16'], ['bool']);
sub mutex_create {
    my ($self, @args) = @_;
    return OpenQA::Scheduler::Locks::create(@args);
}

dbus_method('mutex_lock', ['string', 'uint16'], ['bool']);
sub mutex_lock {
    my ($self, @args) = @_;
    return OpenQA::Scheduler::Locks::lock(@args);
}

dbus_method('mutex_unlock', ['string', 'uint16'], ['bool']);
sub mutex_unlock {
    my ($self, @args) = @_;
    return OpenQA::Scheduler::Locks::unlock(@args);

}
1;
