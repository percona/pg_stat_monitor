#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use IPC::Run;
use PostgreSQL::Test::Cluster;
use lib 't';
use pgsm;

my $orig_stdout;
my $orig_stderr;

BEGIN
{
	# PostgreSQL's test suite redirects stdout/sterr to a log file so we need
	# to save them before the redirection happens.
	open($orig_stdout, '>&', \*STDOUT) or die $!;
	open($orig_stderr, '>&', \*STDERR) or die $!;
}

my @tests = qw(
  basic
  version
  guc
  pgsm_query_id
  functions
  counters
  relations
  database
  error_insert
  application_name
  application_name_unique
  top_query
  different_parent_queries
  cmd_type
  error
  rows
  squashing
  tags
  user
  rollback
  level_tracking
  decode_error_level
  parallel
  histogram
);

my $node = PGSM->pgsm_init_pg;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_monitor'");
$node->start;

IPC::Run::run [
	$ENV{PG_REGRESS},
	'--host' => $node->host,
	'--port' => $node->port,
	'--dbname' => 'pgsm_regression',
	'--inputdir' => ($ENV{'top_builddir'} || '.') . '/regression',
	'--outputdir' => ($ENV{'top_builddir'} || '.') . '/regression',
	%{ $PGSM::PG_MAJOR_VERSION >= 16 ? { '--expecteddir' => ($ENV{'top_builddir'} || '.') . '/regression' } : {} },
	@tests,
],
'1>' => $orig_stdout,
'2>' => $orig_stderr
or exit $?;

$node->stop;
