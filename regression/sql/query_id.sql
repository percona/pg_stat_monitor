CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track_utility = on;
SET pg_stat_monitor.pgsm_track_planning = on;
SET pg_stat_monitor.pgsm_normalized_query = on;

--
-- Do not store queries without a query identifier
--
SET compute_query_id = off;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
SELECT 1 AS no_query_id;
CREATE TABLE no_query_id_tab (x int);
INSERT INTO no_query_id_tab VALUES (1);
SELECT x FROM no_query_id_tab;
PREPARE no_query_id_prep AS SELECT x FROM no_query_id_tab WHERE x = $1;
EXECUTE no_query_id_prep(1);
DEALLOCATE no_query_id_prep;
DROP TABLE no_query_id_tab;
DO $$
BEGIN
    PERFORM 1;
END
$$;
-- Nothing of the above was recorded.
SELECT count(*) FROM pg_stat_monitor;

--
-- Tracking resumes once query identifiers are computed again.
--
RESET compute_query_id;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
SELECT 1 AS with_query_id;
SELECT calls, query FROM pg_stat_monitor
    WHERE query LIKE '%with_query_id%' ORDER BY query COLLATE "C";

SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
