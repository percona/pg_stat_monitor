CREATE EXTENSION pg_stat_monitor;
SELECT pg_stat_monitor_reset();
SET application_name = 'naeem';
SELECT 1 AS num;
SET application_name = 'psql';
SELECT 1 AS num;
SELECT query, application_name FROM pg_stat_monitor ORDER BY query, application_name COLLATE "C";
SELECT pg_stat_monitor_reset();

-- Check for prepared statements

-- Use generic plan to avoid re-parsing and planner call
SET plan_cache_mode = force_generic_plan;
PREPARE p AS SELECT set_config('application_name', 'selfset', false);

EXECUTE p;
SET application_name = 'another_name';
EXECUTE p;

-- Prepared statements should not have application_name 'selfset'
SELECT query, application_name FROM pg_stat_monitor ORDER BY query, application_name COLLATE "C";

DEALLOCATE p;
RESET application_name;
RESET plan_cache_mode;
SELECT pg_stat_monitor_reset();

DROP EXTENSION pg_stat_monitor;
