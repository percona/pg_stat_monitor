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

# CREATE new PostgreSQL node and do initdb
my $node = PGSM->pgsm_init_pg();

$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor'
# Set bucket duration to 36000 seconds so bucket doesn't change.
pg_stat_monitor.pgsm_bucket_time = 36000
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

my $port = $node->port;

my $out = system("pgbench -i -s 10 -p $port postgres");
is($cmdret, 0, "Perform pgbench init");

$out = system("pgbench -c 10 -j 2 -t 1000 -p $port postgres");
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
	"SELECT pg_sleep(2);",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
is($cmdret, 0, "Run pg_sleep for 2 seconds ");
PGSM::append_to_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT substr(query, 0, 30), calls, rows, round(total_exec_time::numeric, 4) AS total_exec_time, round(min_exec_time::numeric, 4) AS min_exec_time, round(max_exec_time::numeric, 4) AS max_exec_time, round(mean_exec_time::numeric, 4) AS mean_exec_time, round(stddev_exec_time::numeric, 4) AS stddev_exec_time, round(${col_shared_blk_read_time}::numeric, 4) AS ${col_shared_blk_read_time}, round(${col_shared_blk_write_time}::numeric, 4) AS ${col_shared_blk_write_time} FROM pg_stat_statements WHERE query LIKE '%bench%' ORDER BY query, calls DESC;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	"SELECT bucket, bucket_start_time, queryid, substr(query, 0, 30) AS query, calls, rows, total_exec_time, min_exec_time, max_exec_time, mean_exec_time, stddev_exec_time, round(${col_shared_blk_read_time}::numeric, 4) AS ${col_shared_blk_read_time}, round(${col_shared_blk_write_time}::numeric, 4) AS ${col_shared_blk_write_time}, cpu_user_time, cpu_sys_time FROM pg_stat_monitor WHERE query LIKE '%bench%' ORDER BY query, calls DESC;",
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT substr(query, 0, 30) AS query, calls, rows, wal_records, wal_fpi, wal_bytes, wal_buffers_full FROM pg_stat_statements WHERE query LIKE \'%bench%\' ORDER BY query, calls;',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
PGSM::append_to_debug_file($stdout);

($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'SELECT bucket, bucket_start_time, substr(query, 0, 30) AS query, calls, rows, wal_records, wal_fpi, wal_bytes, wal_buffers_full, cmd_type_text FROM pg_stat_monitor WHERE query LIKE \'%bench%\' ORDER BY query, calls;',
	extra_params => [ '-a', '-Pformat=aligned', '-Ptuples_only=off' ]);
PGSM::append_to_debug_file($stdout);

# Compare values for query 'DELETE FROM pgbench_accounts WHERE $1 = $2'
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.calls) = sum(pgss.calls) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: calls are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.rows) = sum(pgss.rows) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: rows are equal).");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.total_exec_time) = sum(round(pgss.total_exec_time::numeric, 4)) OR sum(pgss.total_exec_time::numeric) % sum(pgsm.total_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: total_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.min_exec_time) = sum(round(pgss.min_exec_time::numeric, 4)) OR sum(pgss.min_exec_time::numeric) % sum(pgsm.min_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: min_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.max_exec_time) = sum(round(pgss.max_exec_time::numeric, 4)) OR sum(pgss.max_exec_time::numeric) % sum(pgsm.max_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: max_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.mean_exec_time) = sum(round(pgss.mean_exec_time::numeric, 4)) OR sum(pgss.mean_exec_time::numeric) % sum(pgsm.mean_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: mean_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.stddev_exec_time) = sum(round(pgss.stddev_exec_time::numeric, 4)) OR sum(pgss.stddev_exec_time::numeric) % sum(pgsm.stddev_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: stddev_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_records) = sum(pgss.wal_records) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_records are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_fpi) = sum(pgss.wal_fpi) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_fpi is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_bytes) = sum(pgss.wal_bytes) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_bytes are equal.");

if ($PGSM::PG_MAJOR_VERSION >= 18)
{
	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.wal_buffers_full) = sum(pgss.wal_buffers_full) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: wal_buffers_full are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_to_launch) = sum(pgss.parallel_workers_to_launch) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_to_launch are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_launched) = sum(pgss.parallel_workers_launched) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%DELETE FROM pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_launched are equal.");
}

# Compare values for query 'INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)'
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.calls) = sum(pgss.calls) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: calls are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.rows) = sum(pgss.rows) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: rows are equal).");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.total_exec_time) = sum(round(pgss.total_exec_time::numeric, 4)) OR sum(pgss.total_exec_time::numeric) % sum(pgsm.total_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: total_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.min_exec_time) = sum(round(pgss.min_exec_time::numeric, 4)) OR sum(pgss.min_exec_time::numeric) % sum(pgsm.min_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: min_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.max_exec_time) = sum(round(pgss.max_exec_time::numeric, 4)) OR sum(pgss.max_exec_time::numeric) % sum(pgsm.max_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: max_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.mean_exec_time) = sum(round(pgss.mean_exec_time::numeric, 4)) OR sum(pgss.mean_exec_time::numeric) % sum(pgsm.mean_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: mean_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.stddev_exec_time) = sum(round(pgss.stddev_exec_time::numeric, 4)) OR sum(pgss.stddev_exec_time::numeric) % sum(pgsm.stddev_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: stddev_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(round(pgsm.${col_shared_blk_read_time}::numeric, 4)) = sum(round(pgss.${col_shared_blk_read_time}::numeric, 4)) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Compare: ${col_shared_blk_read_time} is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(round(pgsm.${col_shared_blk_write_time}::numeric, 4)) = sum(round(pgss.${col_shared_blk_write_time}::numeric, 4)) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Compare: ${col_shared_blk_write_time} is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_records) = sum(pgss.wal_records) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_records are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_fpi) = sum(pgss.wal_fpi) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_fpi is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_bytes) = sum(pgss.wal_bytes) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_bytes are equal.");

if ($PGSM::PG_MAJOR_VERSION >= 18)
{
	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.wal_buffers_full) = sum(pgss.wal_buffers_full) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: wal_buffers_full are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_to_launch) = sum(pgss.parallel_workers_to_launch) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_to_launch are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_launched) = sum(pgss.parallel_workers_launched) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%INSERT INTO pgbench_history%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_launched are equal.");
}

# Compare values for query 'SELECT abalance FROM pgbench_accounts WHERE aid = $1'
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.calls) = sum(pgss.calls) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: calls are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.rows) = sum(pgss.rows) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: rows are equal).");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.total_exec_time) = sum(round(pgss.total_exec_time::numeric, 4)) OR sum(pgss.total_exec_time::numeric) % sum(pgsm.total_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: total_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.min_exec_time) = sum(round(pgss.min_exec_time::numeric, 4)) OR sum(pgss.min_exec_time::numeric) % sum(pgsm.min_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: min_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.max_exec_time) = sum(round(pgss.max_exec_time::numeric, 4)) OR sum(pgss.max_exec_time::numeric) % sum(pgsm.max_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: max_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.mean_exec_time) = sum(round(pgss.mean_exec_time::numeric, 4)) OR sum(pgss.mean_exec_time::numeric) % sum(pgsm.mean_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: mean_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.stddev_exec_time) = sum(round(pgss.stddev_exec_time::numeric, 4)) OR sum(pgss.stddev_exec_time::numeric) % sum(pgsm.stddev_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: stddev_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(round(pgsm.${col_shared_blk_read_time}::numeric, 4)) = sum(round(pgss.${col_shared_blk_read_time}::numeric, 4)) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Compare: ${col_shared_blk_read_time} is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(round(pgsm.${col_shared_blk_write_time}::numeric, 4)) = sum(round(pgss.${col_shared_blk_write_time}::numeric, 4)) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Compare: ${col_shared_blk_write_time} is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_records) = sum(pgss.wal_records) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_records are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_fpi) = sum(pgss.wal_fpi) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_fpi is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_bytes) = sum(pgss.wal_bytes) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_bytes are equal.");

if ($PGSM::PG_MAJOR_VERSION >= 18)
{
	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.wal_buffers_full) = sum(pgss.wal_buffers_full) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: wal_buffers_full are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_to_launch) = sum(pgss.parallel_workers_to_launch) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_to_launch are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_launched) = sum(pgss.parallel_workers_launched) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%SELECT abalance FROM pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_launched are equal.");
}

# Compare values for query 'UPDATE pgbench_accounts SET abalance = abalance + $1 WHERE aid = $2'
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.calls) = sum(pgss.calls) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: calls are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.rows) = sum(pgss.rows) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: rows are equal).");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.total_exec_time) = sum(round(pgss.total_exec_time::numeric, 4)) OR sum(pgss.total_exec_time::numeric) % sum(pgsm.total_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: total_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.min_exec_time) = sum(round(pgss.min_exec_time::numeric, 4)) OR sum(pgss.min_exec_time::numeric) % sum(pgsm.min_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: min_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.max_exec_time) = sum(round(pgss.max_exec_time::numeric, 4)) OR sum(pgss.max_exec_time::numeric) % sum(pgsm.max_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: max_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.mean_exec_time) = sum(round(pgss.mean_exec_time::numeric, 4)) OR sum(pgss.mean_exec_time::numeric) % sum(pgsm.mean_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: mean_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.stddev_exec_time) = sum(round(pgss.stddev_exec_time::numeric, 4)) OR sum(pgss.stddev_exec_time::numeric) % sum(pgsm.stddev_exec_time::numeric) < 1 FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: stddev_exec_time is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	"SELECT sum(round(pgsm.${col_shared_blk_write_time}::numeric, 4)) = sum(round(pgss.${col_shared_blk_write_time}::numeric, 4)) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;"
);
trim($stdout);
is($stdout, 't', "Compare: ${col_shared_blk_write_time} is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_records) = sum(pgss.wal_records) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_records are equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_fpi) = sum(pgss.wal_fpi) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_fpi is equal.");

($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT sum(pgsm.wal_bytes) = sum(pgss.wal_bytes) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
);
trim($stdout);
is($stdout, 't', "Compare: wal_bytes are equal.");

if ($PGSM::PG_MAJOR_VERSION >= 18)
{
	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.wal_buffers_full) = sum(pgss.wal_buffers_full) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: wal_buffers_full are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_to_launch) = sum(pgss.parallel_workers_to_launch) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_to_launch are equal.");

	($cmdret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT sum(pgsm.parallel_workers_launched) = sum(pgss.parallel_workers_launched) FROM pg_stat_monitor AS pgsm INNER JOIN pg_stat_statements AS pgss ON pgss.query = pgsm.query WHERE pgsm.query LIKE \'%UPDATE pgbench_accounts%\' GROUP BY pgsm.query;'
	);
	trim($stdout);
	is($stdout, 't', "Compare: parallel_workers_launched are equal.");
}

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
