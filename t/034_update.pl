#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use File::Compare;
use Test::More;
use lib 't';
use pgsm;

# Get filename and create out file name and dirs where requried
PGSM::setup_files_dir(basename($0));

# Create new PostgreSQL node and do initdb
my $node = PGSM->pgsm_init_pg();
my $pgdata = $node->data_dir;

# Update postgresql.conf to include/load pg_stat_monitor library
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_stat_monitor'");

# Start server
my $rt_value = $node->start;
ok($rt_value == 1, "Start Server");

# Create EXTENSION version 2.0
my ($cmdret, $stdout, $stderr) = $node->psql('postgres', 'CREATE EXTENSION pg_stat_monitor VERSION "2.0";', extra_params => ['-a']);
ok($cmdret == 0, "Create PGSM EXTENSION");
PGSM::append_to_debug_file($stdout);

# Check that we have some results for version 2.0
($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT * FROM pg_stat_monitor;", extra_params => ['-a']);
ok($cmdret == 0, "Check PGSM returns some results for version 2.0");
PGSM::append_to_debug_file($stdout);

# Update EXTENSION to new version 2.1
($cmdret, $stdout, $stderr) = $node->psql('postgres', 'ALTER EXTENSION pg_stat_monitor UPDATE TO "2.1";', extra_params => ['-a']);
ok($cmdret == 0, "Update PGSM EXTENSION to new version");
PGSM::append_to_debug_file($stdout);

# Check that we have some results for version 2.1
($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT * FROM pg_stat_monitor;", extra_params => ['-a']);
ok($cmdret == 0, "Check PGSM returns some results for version 2.1");
PGSM::append_to_debug_file($stdout);

# DROP EXTENSION
$stdout = $node->safe_psql('postgres', 'DROP EXTENSION pg_stat_monitor;', extra_params => ['-a']);
ok($cmdret == 0, "DROP PGSM EXTENSION");
PGSM::append_to_debug_file($stdout);

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
