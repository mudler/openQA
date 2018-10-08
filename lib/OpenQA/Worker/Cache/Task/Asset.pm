# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Worker::Cache::Task::Asset;

use Mojo::Base 'Mojolicious::Plugin';
use Mojo::URL;
use constant LOCK_RETRY_DELAY   => 30;
use constant MINION_LOCK_EXPIRE => 999999999;

use OpenQA::Worker::Cache::Client;
use OpenQA::Worker::Cache;

has ua     => sub { Mojo::UserAgent->new };
has cache  => sub { OpenQA::Worker::Cache->from_worker };
has client => sub { OpenQA::Worker::Cache::Client->new };

sub dequeue { shift->client->dequeue_job(pop) }
sub _gen_guard_name { join('.', shift->client->session_token, pop) }

sub register {
    my ($self, $app) = @_;
    # Make it a helper
    $app->helper(asset_task => sub { $self });

    $app->minion->add_task(
        cache_asset => sub {
            my ($job, $id, $type, $asset_name, $host) = @_;
            my $guard_name = $self->_gen_guard_name($asset_name);
            return $job->remove unless defined $asset_name && defined $type && defined $host;

            return $job->retry({delay => LOCK_RETRY_DELAY})
              unless my $guard = $app->minion->guard($guard_name, MINION_LOCK_EXPIRE);
            $app->log->debug("[$$] [Job #" . $job->id . "] Guard: $guard_name Download: $asset_name");

            $app->log->debug("[$$] Job dequeued ") if $self->dequeue($asset_name);
            $OpenQA::Utils::app = undef;
            {
                my $output;
                open my $handle, '>', \$output;
                local *STDERR = $handle;
                local *STDOUT = $handle;
                # Do the real download
                $self->cache->host($host);
                $self->cache->get_asset({id => $id}, $type, $asset_name);
                $job->note(output => $output);
                print $output;
            }

            $app->log->debug("[$$] [Job #" . $job->id . "] Finished");
        });
}

1;
