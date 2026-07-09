#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Text::Trim qw(trim);
use Test::More;
use lib 't';
use pgsm;

# Get file name and CREATE out file name and dirs WHERE requried
PGSM::setup_files_dir(basename($0));

if ($PGSM::PG_MAJOR_VERSION <= 12)
{
	plan skip_all => "pg_stat_monitor test cases for versions 12 and below.";
}

# CREATE new PostgreSQL node and do initdb
my $node = PGSM->pgsm_init_pg();

$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor'
# Set bucket duration to 360000 seconds so bucket doesn't change.
pg_stat_monitor.pgsm_bucket_time = 360000
track_io_timing = on
pg_stat_monitor.pgsm_track_utility = off
pg_stat_monitor.pgsm_normalized_query = on
));

# Start server
$node->start;

my $col_shared_blk_read_time = "shared_blk_read_time";
my $col_shared_blk_write_time = "shared_blk_write_time";

if ($PGSM::PG_MAJOR_VERSION <= 16)
{
	$col_shared_blk_read_time = "blk_read_time";
	$col_shared_blk_write_time = "blk_write_time";
}

# CREATE EXTENSION and change out file permissions
my ($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION pg_stat_statements;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE PGSS EXTENSION");
PGSM::append_to_file($stdout);

# CREATE EXTENSION and change out file permissions
($cmdret, $stdout, $stderr) = $node->psql(
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

# Run required commands/queries and dump output to out file.
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT pg_stat_statements_reset();',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Reset PGSS EXTENSION");
PGSM::append_to_file($stdout);

# Run 'SELECT ****' two times and dump output to out file
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT name, setting, unit, context, vartype, source, min_val, max_val, enumvals, boot_val, reset_val, pending_restart FROM pg_settings WHERE name LIKE '%pg_stat_monitor%';",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Print PGSM EXTENSION Settings");
PGSM::append_to_file($stdout);

# CREATE example database and run pgbench init
# ($cmdret, $stdout, $stderr) = $node->psql('postgres', 'CREATE DATABASE example;', extra_params => ['-a']);
# is($cmdret, 0, "CREATE DATABASE example");
# PGSM::append_to_file($stdout);

my $port = $node->port;

my $out = system("pgbench -i -s 20 -p $port postgres");
is($cmdret, 0, "Perform pgbench init");

$out = system("pgbench -c 10 -j 2 -t 2000 -p $port postgres");
is($cmdret, 0, "Run pgbench");

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"DELETE FROM pgbench_accounts WHERE aid % 9 = 1;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"DELETE FROM pgbench_accounts WHERE aid % 10 = 1;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"DELETE FROM pgbench_accounts WHERE aid % 5 = 1;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"DELETE FROM pgbench_accounts WHERE aid % 3 = 1;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"DELETE FROM pgbench_accounts WHERE aid % 2 = 1;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT substr(query, 0, 130) AS query, calls, rows, total_exec_time, min_exec_time, max_exec_time, mean_exec_time, stddev_exec_time FROM pg_stat_statements WHERE query LIKE \'%bench%\' ORDER BY query, calls DESC;',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT substr(query, 0, 130) AS query, calls, rows, total_exec_time, min_exec_time, max_exec_time, mean_exec_time, stddev_exec_time, cpu_user_time, cpu_sys_time FROM pg_stat_monitor WHERE query LIKE \'%bench%\' ORDER BY query, calls DESC;',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
PGSM::append_to_debug_file($stdout);
PGSM::append_to_debug_file("--------");

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT substr(query, 0, 130) AS query, calls, rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, ${col_shared_blk_read_time}, ${col_shared_blk_write_time} FROM pg_stat_monitor WHERE query LIKE '%bench%' ORDER BY query, calls DESC;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
PGSM::append_to_debug_file($stdout);

# Compare values for query 'DELETE FROM pgbench_accounts WHERE $1 = $2'
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_hit) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_hit should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_read) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_read should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_dirtied) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_dirtied should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_written) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_written should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(pgsm.${col_shared_blk_read_time}) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE '%DELETE FROM pgbench_accounts%' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Check: ${col_shared_blk_read_time} should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(pgsm.${col_shared_blk_write_time}) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE '%DELETE FROM pgbench_accounts%' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Check: ${col_shared_blk_write_time} should not be 0.");

# Compare values for query 'INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)'
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_hit) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_hit should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_dirtied) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_dirtied should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_written) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_written should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(pgsm.${col_shared_blk_write_time}) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE '%INSERT INTO pgbench_history%' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Check: ${col_shared_blk_write_time} should not be 0.");

# Compare values for query 'UPDATE pgbench_accounts SET abalance = abalance + $1 WHERE aid = $2'
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_hit) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts SET abalance%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_hit should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_read) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts SET abalance%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_read should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_dirtied) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts SET abalance%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_dirtied should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.shared_blks_written) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts SET abalance%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Check: shared_blks_written should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(pgsm.${col_shared_blk_read_time}) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE '%UPDATE pgbench_accounts SET abalance%' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Check: ${col_shared_blk_read_time} should not be 0.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(pgsm.${col_shared_blk_write_time}) <> 0 FROM pg_stat_monitor AS pgsm WHERE pgsm.query LIKE '%UPDATE pgbench_accounts SET abalance%' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Check: ${col_shared_blk_write_time} should not be 0.");

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
