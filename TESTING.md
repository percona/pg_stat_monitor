# How to run the tests

This document describes how to run the tests suites when building pg & pgsm from source.

The steps can also be adapted when postgres is installed using a package manager, in that case the relevant directories will be in their usual global locations (`/usr/lib/postgresql`)

## pg_regress

1. setup and start a postgres cluster
2. create a database named "contrib\_regression"
3. Install the pg\_stat\_statements extension
4. Run the tests using (with the working directory as the pgsm git repository):

   ```
   <PG_BUILD_DIR>/src/test/regress/pg_regress --bindir <INST_DIR>/bin --temp-config pg_stat_monitor.conf --inputdir regression/ --dbname=contrib_regression basic version guc pgsm_query_id functions counters relations database error_insert application_name application_name_unique top_query cmd_type error rows tags user
   ```

# prove

1. setup and start postgres cluster
2. create a database named "contrib\_regression"
3. Install the pg\_stat\_monitor and pg\_stat\_statements extensions
4. When executing the tests multiple times, delete the `tmp_check` directory between runs
5. When executing the tests and encountering failures, databases created by some tests might remain in the cluster.
   Connect to the cluster, and delete these databases if they cause errors.
6. Run the tests using (with the working directory as the pgsm git repository):

   ```
   prove -I <PG_SRC_DIR>/src/src/test/perl/ -I . t/*.pl
   ```

