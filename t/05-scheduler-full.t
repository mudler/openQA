#!/usr/bin/env perl -w

# Copyright (C) 2014-2017 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Mojo::File qw(path tempdir);
BEGIN {
    unshift @INC, 'lib';
    #  push @INC, '.';
    use FindBin;
    $ENV{OPENQA_BASEDIR} = path(tempdir, 't', 'scheduler');
    $ENV{OPENQA_CONFIG} = path($ENV{OPENQA_BASEDIR}, 'config')->make_path;
    # Since tests depends on timing, we require the scheduler to be fixed in its actions.
    $ENV{OPENQA_SCHEDULER_TIMESLOT}               = 1000;
    $ENV{OPENQA_SCHEDULER_MAX_JOB_ALLOCATION}     = 10;
    $ENV{OPENQA_SCHEDULER_FIND_JOB_ATTEMPTS}      = 2;
    $ENV{OPENQA_SCHEDULER_CONGESTION_CONTROL}     = 1;
    $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS}       = 2000;
    $ENV{OPENQA_SCHEDULER_MAX_BACKOFF}            = 4000;
    $ENV{OPENQA_SCHEDULER_CAPTURE_LOOP_AVOIDANCE} = 38000;
    $ENV{OPENQA_SCHEDULER_WAKEUP_ON_REQUEST}      = 0;
    path($FindBin::Bin, "data")->child("openqa.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("openqa.ini"));
    path($FindBin::Bin, "data")->child("database.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("database.ini"));
    path($FindBin::Bin, "data")->child("workers.ini")->copy_to(path($ENV{OPENQA_CONFIG})->child("workers.ini"));
    path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->make_path->child("db.lock")->spurt;
}

use strict;
use lib "$FindBin::Bin/lib";
use Data::Dump qw(pp dd);
use OpenQA::Scheduler;
use OpenQA::Scheduler::Scheduler;
use OpenQA::Test::Database;
use Test::More;
use Net::DBus qw(:typing);
use Mojo::IOLoop::Server;
use OpenQA::Test::Utils
  qw(create_webapi create_websocket_server create_worker kill_service unstable_worker client_output);
use Mojolicious;
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path getcwd);
use DateTime;
# This test have to be treated like fullstack.
plan skip_all => "set FULLSTACK=1 (be careful)" unless $ENV{FULLSTACK};

init_db();
my $schema = OpenQA::Test::Database->new->create();

# Create webapi and websocket server services.
my $mojoport = Mojo::IOLoop::Server->generate_port();
my $wspid    = create_websocket_server($mojoport + 1);
my $webapi   = create_webapi($mojoport);

# Setup needed files for workers.
my $sharedir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'share')->make_path;

path($sharedir, 'factory', 'iso')->make_path;

symlink(abs_path("../os-autoinst/t/data/Core-7.2.iso"),
    path($sharedir, 'factory', 'iso')->child("Core-7.2.iso")->to_string)
  || die "can't symlink";

path($sharedir, 'tests')->make_path;

symlink(abs_path('../os-autoinst/t/data/tests/'), path($sharedir, 'tests')->child("tinycore"))
  || die "can't symlink";

my $resultdir = path($ENV{OPENQA_BASEDIR}, 'openqa', 'testresults')->make_path;
ok -d $resultdir;

# Instantiate our (hacked) scheduler
my $reactor = get_reactor();


my $k = $schema->resultset("ApiKeys")->create({user_id => "99903"});

subtest 'Scheduler backoff timing calculations' => sub {
    dead_workers($schema);

    my $allocated;
    my $failures;
    my $no_actions;
    my $c;
    for (0 .. 5) {
        $c++;
        ($allocated, $failures, $no_actions) = scheduler_step($reactor);
        is $failures, $c, "Expected failures: $c";
        is @$allocated, 0, "Expected allocations: 0";
        is $no_actions, $c, "No actions performed will match failures - since we have no free workers";
    }



    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   7;
    is $no_actions, 7;
    is @$allocated, 0;
};

#
subtest 'Scheduler worker job allocation' => sub {

    my $allocated;
    my $failures;
    my $no_actions;

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   8;
    is $no_actions, $failures;
    is @$allocated, 0;

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   9;
    is $no_actions, $failures;
    is @$allocated, 0;

    # Step 1
    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   10;
    is $no_actions, $failures;
    is @$allocated, 0;

    # Capture loop avoidance timer fired. back to default
    trigger_capture_event_loop($reactor);
    # Step 1
    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   1;
    is $no_actions, $failures;
    is @$allocated, 0;
    #  my $k = $schema->resultset("ApiKeys")->create({user_id => "99903"});

    # GO GO GO GO GO!!! like crazy now
    my $w1_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 1);
    my $w2_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 2);
    sleep 5;

    # Step 1
    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures, 0;
    is @$allocated, 2;

    my $job_id1 = $allocated->[0]->{job};
    my $job_id2 = $allocated->[1]->{job};
    my $wr_id1  = $allocated->[0]->{worker};
    my $wr_id2  = $allocated->[1]->{worker};
    ok $wr_id1 != $wr_id2,   "Jobs dispatched to different workers";
    ok $job_id1 != $job_id2, "Jobs dispatched to different workers";


    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    #    is @$running, 0, 'Scheduler did nothing since jobs failed immediately';
    is $failures,   0;
    is $no_actions, 2;
    is @$allocated, 0;

    dead_workers($schema);

    kill_service($_, 1) for ($w1_pid, $w2_pid);
};

subtest 'Simulation of unstable workers' => sub {
    my $allocated;
    my $failures;
    my $no_actions;


    my @latest = $schema->resultset("Jobs")->latest_jobs;

    shift(@latest)->auto_duplicate();

    ($allocated, $failures, $no_actions) = scheduler_step($reactor); # Will try to allocate to previous worker and fail!
    is $failures,   1;
    is $no_actions, 3;



    #Now let's simulate unstable workers :)
    # 3 is the instance, and 7 is ticks that have to be are performed
    # In this way the worker will associate, will be registered but won't close the ws connection.
    my $unstable_w_pid = unstable_worker($k->key, $k->secret, "http://localhost:$mojoport", 3, 7);

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   0;
    is $no_actions, 0;
    is @$allocated, 1;

    kill_service($unstable_w_pid, 1);

    #
    # ($allocated, $duplicates, $failures) = scheduler_step($reactor);
    # is @$allocated,  0;
    # is @$duplicates, 0;
    # is @{$duplicates}[0]->{old}, 99982;
    # is @{$duplicates}[0]->{new}, 99983;
    # is $schema->resultset("Jobs")->find(99982)->result, OpenQA::Schema::Result::Jobs::INCOMPLETE;
    #
    # is $failures, 2;
    #
    #  $schema->resultset("Jobs")->find(99983)->delete;
    dead_workers($schema);
};

subtest 'Simulation of running workers (normal)' => sub {
    dead_workers($schema);

    scheduler_step($reactor);
    scheduler_step($reactor);


    my $allocated;
    my $failures;
    my $no_actions;


    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   1;
    is $no_actions, 3;
    is @$allocated, 0;

    # Capture loop avoidance timer fired. back to default
    trigger_capture_event_loop($reactor);

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   0;
    is $no_actions, 1;
    is @$allocated, 0;

    dead_workers($schema);
    my $JOB_SETUP
      = 'ISO=Core-7.2.iso DISTRI=tinycore ARCH=i386 QEMU=i386 QEMU_NO_KVM=1 '
      . 'FLAVOR=flavor BUILD=1 MACHINE=coolone QEMU_NO_TABLET=1 INTEGRATION_TESTS=1'
      . 'QEMU_NO_FDC_SET=1 CDMODEL=ide-cd HDDMODEL=ide-drive VERSION=1 TEST=core PUBLISH_HDD_1=core-hdd.qcow2';
    # schedule job
    #diag client_output($k->key, $k->secret, "http://localhost:$mojoport", "jobs post $JOB_SETUP");
    my @latest = $schema->resultset("Jobs")->latest_jobs;

    shift(@latest)->auto_duplicate();
    sleep 5;

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is $failures,   0;
    is $no_actions, $failures;
    is @$allocated, 0;

    #reset_tick($reactor);

    my $w1_pid = create_worker($k->key, $k->secret, "http://localhost:$mojoport", 1);
    sleep 10;

    ($allocated, $failures, $no_actions) = scheduler_step($reactor);
    is @$allocated, 1;
    is @{$allocated}[0]->{job},    99983;
    is @{$allocated}[0]->{worker}, 3;
    is $no_actions, 0;
    is $failures,   0;

    dead_workers($schema);
    kill_service($w1_pid, 1);
};

kill_service($_) for ($wspid, $webapi);

sub dead_workers {
    my $schema = shift;
    $_->update({t_updated => DateTime->from_epoch(epoch => time - 10200)}) for $schema->resultset("Workers")->all();
}

sub reset_tick {
    my $reactor = shift;

    $reactor->remove_timeout($reactor->{timer}->{schedule_jobs});
    delete $reactor->{timer}->{schedule_jobs};
    $reactor->{tick} = $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};    # Reset to what we expect to be normal ticking
    return $reactor;
}

sub trigger_capture_event_loop {
    my $reactor = shift;
    # Capture loop avoidance timer fired. back to default
    scheduler_step($reactor);
    is $reactor->{timeouts}->[$reactor->{timer}->{schedule_jobs}]->{interval},
      $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS} + 1000, "Scheduler clock got reset";
    reset_tick($reactor);
    return $reactor;
}

sub get_reactor {
    # Instantiate our (hacked) scheduler
    OpenQA::Scheduler->new();
    my $reactor = Net::DBus::Reactor->main;
    OpenQA::Scheduler::Scheduler::reactor($reactor);
    $reactor->{tick} //= $ENV{OPENQA_SCHEDULER_SCHEDULE_TICK_MS};
    return $reactor;
}

sub range_ok {
    my ($tick, $started, $fired) = @_;
    my $step       = 1000;
    my $low_limit  = $tick - $step;
    my $high_limit = $tick + $step;
    my $delta      = $fired - $started;
    ok($delta > $low_limit && $delta < $high_limit,
        "timeout in range $low_limit->$high_limit (setted tick $tick, real tick occurred at $delta)");
}

sub scheduler_step {
    use Data::Dumper;
    my $reactor = shift;
    my $started = $reactor->_now;
    my ($allocated, $failures, $no_actions, $rescheduled);
    my $fired;
    my $current_tick = $reactor->{tick};
    $reactor->{timer}->{schedule_jobs} = $reactor->add_timeout(
        $current_tick,
        Net::DBus::Callback->new(
            method => sub {
                $fired = $reactor->_now;
                ($allocated, $failures, $no_actions, $rescheduled) = OpenQA::Scheduler::Scheduler::schedule();
                print STDERR Dumper($allocated) . "\n";

                $reactor->{tick} = $reactor->{timeouts}->[$reactor->{timer}->{schedule_jobs}]->{interval};
                $reactor->remove_timeout($reactor->{timer}->{schedule_jobs});    # Scheduler reallocate itself :)
                                                                                 #  $reactor->shutdown;
            }));
    $reactor->{running} = 1;
    $reactor->step;

    range_ok($current_tick, $started, $fired) if $fired;

    my $backoff = ((2**((($failures ? $failures : 0) + ($no_actions ? $no_actions : 0)) || 2)) - 1)
      * $ENV{OPENQA_SCHEDULER_TIMESLOT};
    $backoff = $backoff > $ENV{OPENQA_SCHEDULER_MAX_BACKOFF} ? $ENV{OPENQA_SCHEDULER_MAX_BACKOFF} : $backoff + 1000;
    is get_scheduler_tick($reactor), $backoff,
      "Tick is at the expected value ($backoff) (failures $failures) (no_actions $no_actions)"
      if $rescheduled;

    return ($allocated, $failures, $no_actions);
}
sub get_scheduler_tick { shift->{tick} }

sub init_db {
    # Setup test DB
    path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string;
    ok -e path($ENV{OPENQA_BASEDIR}, 'openqa', 'db')->child("db.lock");
    ok(open(my $conf, '>', path($ENV{OPENQA_CONFIG})->child("database.ini")->to_string));
    print $conf <<"EOC";
  [production]
  dsn = dbi:SQLite:dbname=$ENV{OPENQA_BASEDIR}/openqa/db/db.sqlite
  on_connect_call = use_foreign_keys
  on_connect_do = PRAGMA synchronous = OFF
  sqlite_unicode = 1
EOC
    close($conf);
    is(system("perl ./script/initdb --init_database"), 0);
    # make sure the assets are prefetched
    ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));
}


done_testing;
