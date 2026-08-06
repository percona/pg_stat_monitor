--
-- Tests with plan cache
--

-- The generic_plan_calls and custom_plan_calls counters require
-- PostgreSQL 19 or later.
SELECT setting::int < 190000 AS skip_test FROM pg_settings where name = 'server_version_num' \gset
\if :skip_test
\quit
\endif

CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_normalized_query = on;

-- The tests of the extended query protocol from upstream are omitted here,
-- see: https://perconadev.atlassian.net/browse/PG-1936

-- Setup
CREATE OR REPLACE FUNCTION select_one_func(int) RETURNS VOID AS $$
DECLARE
    ret INT;
BEGIN
    SELECT $1 INTO ret;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE PROCEDURE select_one_proc(int) AS $$
DECLARE
    ret INT;
BEGIN
    SELECT $1 INTO ret;
END;
$$ LANGUAGE plpgsql;

-- Prepared statements
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
PREPARE p1 AS SELECT $1 AS a;
SET plan_cache_mode TO force_generic_plan;
EXECUTE p1(1);
SET plan_cache_mode TO force_custom_plan;
EXECUTE p1(1);
SELECT calls, generic_plan_calls, custom_plan_calls, query FROM pg_stat_monitor
    ORDER BY query COLLATE "C";
DEALLOCATE p1;

-- EXPLAIN [ANALYZE] EXECUTE
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
PREPARE p1 AS SELECT $1;
SET plan_cache_mode TO force_generic_plan;
EXPLAIN (COSTS OFF) EXECUTE p1(1);
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF) EXECUTE p1(1);
SET plan_cache_mode TO force_custom_plan;
EXPLAIN (COSTS OFF) EXECUTE p1(1);
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF) EXECUTE p1(1);
SELECT calls, generic_plan_calls, custom_plan_calls, toplevel, query FROM pg_stat_monitor
    ORDER BY query COLLATE "C";
RESET pg_stat_monitor.pgsm_track;
DEALLOCATE p1;

-- Functions/procedures
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
SET plan_cache_mode TO force_generic_plan;
SELECT select_one_func(1);
CALL select_one_proc(1);
SET plan_cache_mode TO force_custom_plan;
SELECT select_one_func(1);
CALL select_one_proc(1);
SELECT calls, generic_plan_calls, custom_plan_calls, toplevel, query FROM pg_stat_monitor
    ORDER BY query COLLATE "C";

--
-- EXPLAIN [ANALYZE] EXECUTE + functions/procedures
--
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
SET plan_cache_mode TO force_generic_plan;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT select_one_func(1);
EXPLAIN (COSTS OFF) SELECT select_one_func(1);
CALL select_one_proc(1);
SET plan_cache_mode TO force_custom_plan;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT select_one_func(1);
EXPLAIN (COSTS OFF) SELECT select_one_func(1);
CALL select_one_proc(1);
SELECT calls, generic_plan_calls, custom_plan_calls, toplevel, query FROM pg_stat_monitor
    ORDER BY query COLLATE "C", toplevel;

RESET pg_stat_monitor.pgsm_track;
RESET plan_cache_mode;

--
-- Cleanup
--
DROP FUNCTION select_one_func(int);
DROP PROCEDURE select_one_proc(int);
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
