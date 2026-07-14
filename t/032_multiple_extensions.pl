#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Test::More;
use lib 't';
use pgsm;

# Get file name and CREATE out file name and dirs WHERE requried
PGSM::setup_files_dir(basename($0));

my $PG_VERSION_STRING = `pg_config --version`;

if (index(lc($PG_VERSION_STRING), lc("percona")) == -1)
{
	plan skip_all =>
	  "pg_stat_monitor test case only for PPG server package install with extensions.";
}

# CREATE new PostgreSQL node and do initdb
my $node = PGSM->pgsm_init_pg();

$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pg_stat_monitor, pgaudit, set_user, pg_repack'
pg_stat_monitor.pgsm_bucket_time = 360000
pg_stat_monitor.pgsm_normalized_query = on
));

# Start server
$node->start;

# Create PGSM extension
my ($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION pg_stat_monitor;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE PGSM EXTENSION");
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT pg_stat_monitor_reset();',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Reset PGSM EXTENSION");
PGSM::append_to_debug_file($stdout);

# Create Other extensions
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS pgaudit;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE pgaudit EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS set_user;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE set_user EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS pg_repack;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE pg_repack EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SET pgaudit.log = 'none'; CREATE EXTENSION IF NOT EXISTS postgis; SET pgaudit.log = 'all';",
	extra_params => ['-a']);
is($cmdret, 0, "CREATE postgis EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS postgis_raster;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE postgis_raster EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS postgis_sfcgal;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE postgis_sfcgal EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE fuzzystrmatch EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS address_standardizer;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE address_standardizer EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS address_standardizer_data_us;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE address_standardizer_data_us EXTENSION");
PGSM::append_to_debug_file($stdout);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION IF NOT EXISTS postgis_tiger_geocoder;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE postgis_tiger_geocoder EXTENSION");
PGSM::append_to_debug_file($stdout);

# Print PGSM settings
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT name, setting, unit, context, vartype, source, min_val, max_val, enumvals, boot_val, reset_val, pending_restart FROM pg_settings WHERE name = 'pg_stat_monitor.pgsm_query_shared_buffer';",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Print PGSM EXTENSION Settings");
PGSM::append_to_debug_file($stdout);

# Create example database and run pgbench init
($cmdret, $stdout, $stderr) =
  $node->psql('postgres', 'CREATE DATABASE example;', extra_params => ['-a']);
is($cmdret, 0, "CREATE DATABASE example");
PGSM::append_to_debug_file($stdout);

my $port = $node->port;

$cmdret = system("pgbench -i -s 20 -p $port example");
is($cmdret, 0, "Perform pgbench init");

$cmdret = system("pgbench -c 10 -j 2 -t 5000 -p $port example");
is($cmdret, 0, "Run pgbench");

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT datname, substr(query, 0, 150) AS query, sum(calls) AS calls FROM pg_stat_monitor GROUP BY datname, query ORDER BY datname, query, calls;',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "SELECT XXX FROM pg_stat_monitor");
PGSM::append_to_debug_file($stdout);

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
