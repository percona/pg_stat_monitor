--
-- Information related to planning
--

CREATE EXTENSION pg_stat_monitor;
-- These tests require planning tracking and query normalization to be enabled.
SET pg_stat_monitor.pgsm_track_planning = on;
SET pg_stat_monitor.pgsm_normalized_query = on;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;

--
-- [re]plan counting
--
CREATE TABLE stats_plan_test ();
PREPARE prep1 AS SELECT COUNT(*) FROM stats_plan_test;
EXECUTE prep1;
EXECUTE prep1;
EXECUTE prep1;
ALTER TABLE stats_plan_test ADD COLUMN x int;
EXECUTE prep1;
SELECT 42;
SELECT 42;
SELECT 42;
SELECT plans, calls, rows, query FROM pg_stat_monitor
    WHERE query NOT LIKE 'PREPARE%' ORDER BY query COLLATE "C";
-- for the prepared statement we expect at least one replan, but cache
-- invalidations could force more
SELECT plans >= 2 AND plans <= calls AS plans_ok, calls, rows, query FROM pg_stat_monitor
    WHERE query LIKE 'PREPARE%' ORDER BY query COLLATE "C";

--
-- Cached plans are not counted
--
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
SET plan_cache_mode TO force_generic_plan;
PREPARE prep2 AS SELECT 42;
EXECUTE prep2;
EXECUTE prep2;
RESET plan_cache_mode;
SELECT plans, calls FROM pg_stat_monitor WHERE query LIKE 'PREPARE prep2%'
    ORDER BY query COLLATE "C";

-- Cleanup
DROP TABLE stats_plan_test;
DEALLOCATE prep1;
DEALLOCATE prep2;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
