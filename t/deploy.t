#!/usr/bin/env perl -w

# Copyright (C) 2014-2016 SUSE LLC
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

use strict;
BEGIN { unshift @INC, 'lib'; }

# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use Test::More;
use Test::Warnings;
use DBIx::Class::DeploymentHandler;
use SQL::Translator;
use OpenQA::Schema;
use Try::Tiny;
use FindBin;

system("dropdb -h $FindBin::Bin/db openqa_test");
system("createdb -h $FindBin::Bin/db openqa_test");

my $schema = OpenQA::Schema::connect_db(mode => 'test', check => 0);
my $dh = DBIx::Class::DeploymentHandler->new(
    {
        schema           => $schema,
        script_directory => 'dbicdh',
        databases        => 'PostgreSQL',
        force_overwrite  => 0,
    });
my $deployed_version;
try {
    $deployed_version = $dh->version_storage->database_version;
};
ok(!$deployed_version, 'DB not deployed by plain schema connection with check => 0');

my $ret = OpenQA::Schema::deployment_check($schema);
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');
is($ret, 2, 'Expected return value (2) for a deployment');

OpenQA::Schema::disconnect_db;
system("dropdb -h $FindBin::Bin/db openqa_test");
system("createdb -h $FindBin::Bin/db openqa_test");
$schema = OpenQA::Schema::connect_db(mode => 'test', check => 0);

# redeploy DB to older version and check if deployment_check upgrades the DB
$dh = DBIx::Class::DeploymentHandler->new(
    {
        schema              => $schema,
        script_directory    => 'dbicdh',
        databases           => 'PostgreSQL',
        sql_translator_args => {add_drop_table => 0},
        force_overwrite     => 1,
    });
$dh->install({version => $dh->schema_version - 2});
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version - 2, 'Schema at correct, old, version');
$ret = OpenQA::Schema::deployment_check($schema);
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');
is($ret, 1, 'Expected return value (1) for an upgrade');

# check another deployment_check call doesn't do a thing
$ret = OpenQA::Schema::deployment_check($schema);
ok($dh->version_storage->database_version, 'DB deployed');
is($dh->version_storage->database_version, $dh->schema_version, 'Schema at correct version');
is($ret, 0, 'Expected return value (0) for no action needed');

SKIP: {
    eval { require SQL::Translator::Producer::Diagram; };

    skip "SQL::Translator::Producer::Diagram not functional", 2 if "$@";

    my $fn = 't/diagram-v' . $schema->VERSION . '.png';
    unlink($fn);
    my $trans = SQL::Translator->new(
        parser        => 'SQL::Translator::Parser::DBIx::Class',
        parser_args   => {dbic_schema => $schema},
        producer      => 'Diagram',
        producer_args => {
            out_file         => $fn,
            show_constraints => 1,
            show_datatypes   => 1,
            show_sizes       => 1,
            show_fk_only     => 0,
            title            => 'openQA database schema version ' . $schema->VERSION,
        });

    ok($trans->translate, "generate graph");
    ok(-e $fn,            "graph png exists");
}

done_testing();
