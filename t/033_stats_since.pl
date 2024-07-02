#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use File::Compare;
use File::Copy;
use Text::Trim qw(trim);
use Test::More;
use lib 't';
use pgsm;

# Get filename and create out file name and dirs where requried
PGSM::setup_files_dir(basename($0));

if ($PGSM::PG_MAJOR_VERSION <= 16)
{
    plan skip_all => "pg_stat_monitor test cases for versions 16 and below.";
}

# Create new PostgreSQL node and do initdb
my $node = PGSM->pgsm_init_pg();
my $pgdata = $node->data_dir;

# Update postgresql.conf to include/load pg_stat_monitor library
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_stat_monitor'");

# Set change postgresql.conf for this test case.
$node->append_conf('postgresql.conf', "pg_stat_monitor.pgsm_bucket_time = 1");
$node->append_conf('postgresql.conf', "pg_stat_monitor.pgsm_max_buckets = 3");
$node->append_conf('postgresql.conf', "pg_stat_monitor.pgsm_normalized_query = yes");
$node->append_conf('postgresql.conf', "pg_stat_monitor.pgsm_track = 'all'");

# Start server
my $rt_value = $node->start;
ok($rt_value == 1, "Start Server");

# Create EXTENSION and change out file permissions
my ($cmdret, $stdout, $stderr) = $node->psql('postgres', 'CREATE EXTENSION pg_stat_monitor;', extra_params => ['-a']);
ok($cmdret == 0, "Create PGSM EXTENSION");
PGSM::append_to_debug_file($stdout);

# Run 'SELECT pg_stat_monitor settings' and dump output to out file
($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT name, setting, unit, context, vartype, source, min_val, max_val, enumvals, boot_val, reset_val, pending_restart FROM pg_settings WHERE name LIKE '%pg_stat_monitor%';", extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($cmdret == 0, "Print PGSM EXTENSION Settings");
PGSM::append_to_debug_file($stdout);

# Run required commands/queries and dump output to out file.
($cmdret, $stdout, $stderr) = $node->psql('postgres', 'SELECT pg_stat_monitor_reset();', extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($cmdret == 0, "Reset PGSM EXTENSION");
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql('postgres', 'SELECT pg_sleep(1);', extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($cmdret == 0, "1 - Run pg_sleep(1)");
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql('postgres', 'SELECT pg_sleep(1);', extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($cmdret == 0, "2 - Run pg_sleep(1)");
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql('postgres', 'SELECT pg_sleep(1);', extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($cmdret == 0, "3 - Run pg_sleep(1)");
PGSM::append_to_debug_file($stdout);

# Check that we have more than one bucket
($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT COUNT(bucket) != 0 AS PGSM FROM pg_stat_monitor WHERE query LIKE '%sleep%';", extra_params => ['-t', '-Pformat=unaligned','-Ptuples_only=on']);
trim($stdout);
is($stdout,'t',"Check: we have more that one bucket");

# Check that stats timestamps are different for each query/bucket
($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT COUNT(DISTINCT stats_since) = COUNT(stats_since) AS PGSM FROM pg_stat_monitor WHERE query LIKE '%sleep%';", extra_params => ['-t', '-Pformat=unaligned','-Ptuples_only=on']);
trim($stdout);
is($stdout,'t',"Check: for every bucket stats_since should be unique");

# Check that minmax_stats_since always match stats_since
($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT COUNT(*) AS ST FROM pg_stat_monitor WHERE query LIKE '%sleep%' AND stats_since != minmax_stats_since;", extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($stdout == 0, "Compare: Calls count is 1");
PGSM::append_to_debug_file($stdout);

# DROP EXTENSION
$stdout = $node->safe_psql('postgres', 'DROP EXTENSION pg_stat_monitor;', extra_params => ['-a']);
ok($cmdret == 0, "DROP PGSM EXTENSION");
PGSM::append_to_debug_file($stdout);

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
