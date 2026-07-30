#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Text::Trim qw(trim);
use Test::More;
use lib 't';
use pgsm;

# Get filename and create out file name and dirs where requried
PGSM::setup_files_dir(basename($0));

if ($PGSM::PG_MAJOR_VERSION < 19)
{
	plan skip_all =>
	  "generic_plan_calls/custom_plan_calls require PostgreSQL 19 or later";
}

# Create new PostgreSQL node and do initdb
my $node = PGSM->pgsm_init_pg();

$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pg_stat_statements, pg_stat_monitor'
# Set bucket duration to 36000 seconds so bucket doesn't change.
pg_stat_monitor.pgsm_bucket_time = 36000
pg_stat_monitor.pgsm_normalized_query = on
));

# Start server
$node->start;

# Create extensions
my ($cmdret, $stdout, $stderr) = $node->psql(
	'postgres',
	'CREATE EXTENSION pg_stat_statements; CREATE EXTENSION pg_stat_monitor;',
	extra_params => ['-a']);
is($cmdret, 0, "CREATE EXTENSIONS");
PGSM::append_to_file($stdout);

# ----------------------------------------------------------------------------
# Prepared statements, simple query protocol.
#
# One execution under a forced generic plan and one under a forced custom plan
# must be recorded as exactly one generic_plan_calls and one custom_plan_calls
# for the prepared statement.
# ----------------------------------------------------------------------------
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres', qq(
SELECT pg_stat_monitor_reset();
SELECT pg_stat_statements_reset();
PREPARE p1 AS SELECT \$1 AS a;
SET plan_cache_mode TO force_generic_plan;
EXECUTE p1(1);
SET plan_cache_mode TO force_custom_plan;
EXECUTE p1(1);
DEALLOCATE p1;
), extra_params => ['-a']);
is($cmdret, 0, "Simple protocol: run prepared statement workload");
PGSM::append_to_file($stdout);

# Sanity: pg_stat_statements recorded the expected counts.
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT coalesce(sum(generic_plan_calls), 0) = 1 AND coalesce(sum(custom_plan_calls), 0) = 1 FROM pg_stat_statements WHERE query LIKE \'%$1 AS a%\';'
);
trim($stdout);
is($stdout, 't',
	"Simple protocol: pg_stat_statements recorded 1 generic and 1 custom plan call"
);

# pg_stat_monitor must record the same counts.
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT coalesce(sum(generic_plan_calls), 0) = 1 AND coalesce(sum(custom_plan_calls), 0) = 1 FROM pg_stat_monitor WHERE query LIKE \'%$1 AS a%\';'
);
trim($stdout);
is($stdout, 't',
	"Simple protocol: pg_stat_monitor recorded 1 generic and 1 custom plan call"
);

# ----------------------------------------------------------------------------
# Prepared statements, extended query protocol (\parse / \bind_named).
# ----------------------------------------------------------------------------
($cmdret, $stdout, $stderr) = $node->psql(
	'postgres', qq(
SELECT pg_stat_monitor_reset();
SELECT pg_stat_statements_reset();
SELECT \$1 AS a \\parse p1
SET plan_cache_mode TO force_generic_plan;
\\bind_named p1 1
;
SET plan_cache_mode TO force_custom_plan;
\\bind_named p1 1
;
\\close_prepared p1
), extra_params => ['-a']);
is($cmdret, 0, "Extended protocol: run prepared statement workload");
PGSM::append_to_file($stdout);

# Sanity: pg_stat_statements recorded the expected counts.
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT coalesce(sum(generic_plan_calls), 0) = 1 AND coalesce(sum(custom_plan_calls), 0) = 1 FROM pg_stat_statements WHERE query LIKE \'%$1 AS a%\';'
);
trim($stdout);
is($stdout, 't',
	"Extended protocol: pg_stat_statements recorded 1 generic and 1 custom plan call"
);

# pg_stat_monitor must record the same counts.
($cmdret, $stdout, $stderr) = $node->psql('postgres',
	'SELECT coalesce(sum(generic_plan_calls), 0) = 1 AND coalesce(sum(custom_plan_calls), 0) = 1 FROM pg_stat_monitor WHERE query LIKE \'%$1 AS a%\';'
);
trim($stdout);
is($stdout, 't',
	"Extended protocol: pg_stat_monitor recorded 1 generic and 1 custom plan call"
);

# Stop the server
$node->stop;

# Done testing for this testcase file.
done_testing();
