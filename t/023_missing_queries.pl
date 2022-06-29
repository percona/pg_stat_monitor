#!/usr/bin/perl

# Tap test for PG-291 / eb4087be4e8cce8eb19d893d9a47975dd19039a0 bug fix.
#
# Before the fix, there were scenarios in which pg_stat_monitor could lose
# queries (thus wrong call count/stats) when transitioning to a new bucket.
# 
# The problem before the fix is described below:
# 1. Say current active bucket number is 1.
# 2. QueryID XYZ has call count (calls) = 4.
# 3. QueryID also has a pending query (not yet finished).
# 4. Bucket 1 timer expires, pg_stat_monitor moves to bucket 2.
# 5. pg_stat_monitor moves only the pending QueryID XYZ to bucket 2.
# 6. Remove QueryID XYZ from bucket 1 (all stats, calls=4, etc..).
# 
# Since only the pending QueryID XYZ was moved to bucket 2, all
# previous statistics for the same QueryID would have been incorrectly
# removed from the previous bucket (1).
#
# PG-291 fixes the problem, by keeping finished queries in the previous bucket
# and moving only the pending query to the new bucket.
#
# This test works as follows:
# 1. Set pg_stat_monitor bucket time to 14 seconds.
# 2. Start PostgreSQL, reset pg_stat_monitor view.
# 3. Execute "SELECT pg_sleep(5)" three times in a row.
# It's expected that the first two queries execute and finish in the
# first bucket, then the last query starts in the same bucket but is finished
# in the next bucket.
# We expect a total query count of 3 for this query, and it must exist in two
# buckets. 

use strict;
use warnings;
use File::Basename;
use File::Compare;
use PostgresNode;
use Test::More;

# Expected folder where expected output will be present
my $expected_folder = "t/expected";

# Results/out folder where generated results files will be placed
my $results_folder = "t/results";

# Check if results folder exists or not, create if it doesn't
unless (-d $results_folder)
{
   mkdir $results_folder or die "Can't create folder $results_folder: $!\n";;
}

# Check if expected folder exists or not, bail out if it doesn't
unless (-d $expected_folder)
{
   BAIL_OUT "Expected files folder $expected_folder doesn't exist: \n";;
}

# Get filename of the this perl file
my $perlfilename = basename($0);

#Remove .pl from filename and store in a variable
$perlfilename =~ s/\.[^.]+$//;
my $filename_without_extension = $perlfilename;

# Create expected filename with path
my $expected_filename = "${filename_without_extension}.out";
my $expected_filename_with_path = "${expected_folder}/${expected_filename}" ;

# Create results filename with path
my $out_filename = "${filename_without_extension}.out";
my $out_filename_with_path = "${results_folder}/${out_filename}" ;

# Delete already existing result out file, if it exists.
if ( -f $out_filename_with_path)
{
   unlink($out_filename_with_path) or die "Can't delete already existing $out_filename_with_path: $!\n";
}

# Create new PostgreSQL node and do initdb
my $node = PostgresNode->get_new_node('test');
my $pgdata = $node->data_dir;
$node->dump_info;
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'pg_stat_monitor'");
# Set bucket duration to 14 seconds so tests don't take too long.
$node->append_conf('postgresql.conf', "pg_stat_monitor.pgsm_bucket_time = 14");

# Start server
my $rt_value = $node->start;
ok($rt_value == 1, "Start Server");

my ($cmdret, $stdout, $stderr) = $node->psql('postgres', 'CREATE EXTENSION pg_stat_monitor;', extra_params => ['-a']);
ok($cmdret == 0, "Create PGSM Extension");
TestLib::append_to_file($out_filename_with_path, $stdout . "\n");

($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT * from pg_stat_monitor_settings;", extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($cmdret == 0, "Print PGSM Extension Settings");
TestLib::append_to_file($out_filename_with_path, $stdout . "\n");

($cmdret, $stdout, $stderr) = $node->psql('postgres', 'SELECT pg_stat_monitor_reset();', extra_params => ['-a', '-Pformat=aligned','-Ptuples_only=off']);
ok($cmdret == 0, "Reset PGSM Extension");
TestLib::append_to_file($out_filename_with_path, $stdout . "\n");

($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT pg_sleep(5)");
ok($cmdret == 0, "1 - SELECT pg_sleep(5)");
TestLib::append_to_file($out_filename_with_path, $stdout . "\n");

($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT pg_sleep(5)");
ok($cmdret == 0, "2 - SELECT pg_sleep(5)");
TestLib::append_to_file($out_filename_with_path, $stdout . "\n");

($cmdret, $stdout, $stderr) = $node->psql('postgres', "SELECT pg_sleep(5)");
ok($cmdret == 0, "3 - SELECT pg_sleep(5)");
TestLib::append_to_file($out_filename_with_path, $stdout . "\n");

($cmdret, $stdout, $stderr) = $node->psql('postgres', 'SELECT bucket, queryid, calls, query FROM pg_stat_monitor;', extra_params => ['-a', '-Pformat=aligned']);
ok($cmdret == 0, "Query pg_stat_monitor view");
TestLib::append_to_file($out_filename_with_path, $stdout . "\n");

sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

my $last_bucket = "";
my $bucket_cnt = 0;
my $calls = 0;

my @lines = split /\n/, $stdout;

foreach my $line(@lines) {
    my @tokens = split /\|/, $line;
    my $bucket = trim($tokens[0]);
    my $queryid = trim($tokens[1]);
    my $ncalls = trim($tokens[2]);
    my $query = trim($tokens[3]);

    TestLib::append_to_file($out_filename_with_path, "calls: " . $calls . "\n");
    TestLib::append_to_file($out_filename_with_path, "bucket_cnt: " . $bucket_cnt . "\n");
    TestLib::append_to_file($out_filename_with_path, "--------------------------------- \n");

    if ($query =~ "SELECT pg_sleep") {
        $calls += $ncalls;
        if ($bucket_cnt == 0) {
            $bucket_cnt += 1;
            $last_bucket = $bucket;
        } elsif ($bucket != $last_bucket) {
            $bucket_cnt += 1;
            $last_bucket = $bucket;
        }
    }
}

TestLib::append_to_file($out_filename_with_path, "calls: " . $calls . "\n");
TestLib::append_to_file($out_filename_with_path, "bucket_cnt: " . $bucket_cnt . "\n");

ok($calls == 3 || $calls == 2, "Check total query count is correct");
ok($bucket_cnt == 2 || $bucket_cnt == 1, "Check total bucket count is correct");

# Stop the server
$node->stop;
# Done testing for this testcase file.
done_testing();


