#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Test::More;
use lib 't';
use pgsm;

# Get file name and CREATE out file name and dirs WHERE requried
PGSM::setup_files_dir(basename($0));

# CREATE new PostgreSQL node and do initdb
my $node = PGSM->pgsm_init_pg();

$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pg_stat_monitor'
pg_stat_monitor.pgsm_histogram_min = 1
));

# Start server
$node->start;

# CREATE EXTENSION and change out file permissions
my ($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION pg_stat_monitor;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE PGSM EXTENSION");
PGSM::append_to_file($stdout);

# Run required commands/queries and dump output to out file.
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT pg_stat_monitor_reset();',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Reset PGSM EXTENSION");
PGSM::append_to_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT name, setting, unit, context, vartype, source, min_val, max_val, enumvals, boot_val, reset_val, pending_restart FROM pg_settings WHERE name = 'pg_stat_monitor.pgsm_histogram_min';",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Print PGSM EXTENSION Settings");
PGSM::append_to_file($stdout);

$node->append_conf('postgresql.conf',
	'pg_stat_monitor.pgsm_histogram_min = 20');
$node->restart();

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT pg_stat_monitor_reset();',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Reset PGSM EXTENSION");
PGSM::append_to_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT name, setting, unit, context, vartype, source, min_val, max_val, enumvals, boot_val, reset_val, pending_restart FROM pg_settings WHERE name = 'pg_stat_monitor.pgsm_histogram_min';",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Print PGSM EXTENSION Settings");
PGSM::append_to_file($stdout);

$node->append_conf('postgresql.conf',
	'pg_stat_monitor.pgsm_histogram_min = 100');
$node->restart();

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT pg_stat_monitor_reset();',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Reset PGSM EXTENSION");
PGSM::append_to_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT name, setting, unit, context, vartype, source, min_val, max_val, enumvals, boot_val, reset_val, pending_restart FROM pg_settings WHERE name = 'pg_stat_monitor.pgsm_histogram_min';",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Print PGSM EXTENSION Settings");
PGSM::append_to_file($stdout);

# Stop the server
$node->stop;

# compare the expected and out file
my $compare = PGSM->compare_results();

# Test/check if expected and result/out file match. If Yes, test passes.
is($compare, 0,
	"Compare Files: $PGSM::expected_filename_with_path and $PGSM::out_filename_with_path files."
);

# Done testing for this testcase file.
done_testing();
