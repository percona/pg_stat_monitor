--
-- Cursors
--

CREATE EXTENSION pg_stat_monitor;
-- These tests require utility tracking and query normalization to be enabled.
SET pg_stat_monitor.pgsm_track_utility = on;
SET pg_stat_monitor.pgsm_normalized_query = on;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;

-- DECLARE
-- SELECT is normalized.
DECLARE cursor_stats_1 CURSOR WITH HOLD FOR SELECT 1;
CLOSE cursor_stats_1;
DECLARE cursor_stats_1 CURSOR WITH HOLD FOR SELECT 2;
CLOSE cursor_stats_1;

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;

-- FETCH
BEGIN;
DECLARE cursor_stats_1 CURSOR WITH HOLD FOR SELECT 2;
DECLARE cursor_stats_2 CURSOR WITH HOLD FOR SELECT 3;
FETCH 1 IN cursor_stats_1;
FETCH 1 IN cursor_stats_2;
CLOSE cursor_stats_1;
CLOSE cursor_stats_2;
COMMIT;

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;

-- Normalization of FETCH statements
BEGIN;
DECLARE pgsm_cursor CURSOR FOR SELECT FROM generate_series(1, 10);
-- implicit directions
FETCH pgsm_cursor;
FETCH 1 pgsm_cursor;
FETCH 2 pgsm_cursor;
FETCH -1 pgsm_cursor;
-- explicit NEXT
FETCH NEXT pgsm_cursor;
-- explicit PRIOR
FETCH PRIOR pgsm_cursor;
-- explicit FIRST
FETCH FIRST pgsm_cursor;
-- explicit LAST
FETCH LAST pgsm_cursor;
-- explicit ABSOLUTE
FETCH ABSOLUTE 1 pgsm_cursor;
FETCH ABSOLUTE 2 pgsm_cursor;
FETCH ABSOLUTE -1 pgsm_cursor;
-- explicit RELATIVE
FETCH RELATIVE 1 pgsm_cursor;
FETCH RELATIVE 2 pgsm_cursor;
FETCH RELATIVE -1 pgsm_cursor;
-- explicit FORWARD
FETCH ALL pgsm_cursor;
-- explicit FORWARD ALL
FETCH FORWARD ALL pgsm_cursor;
-- explicit FETCH FORWARD
FETCH FORWARD pgsm_cursor;
FETCH FORWARD 1 pgsm_cursor;
FETCH FORWARD 2 pgsm_cursor;
FETCH FORWARD -1 pgsm_cursor;
-- explicit FETCH BACKWARD
FETCH BACKWARD pgsm_cursor;
FETCH BACKWARD 1 pgsm_cursor;
FETCH BACKWARD 2 pgsm_cursor;
FETCH BACKWARD -1 pgsm_cursor;
-- explicit BACKWARD ALL
FETCH BACKWARD ALL pgsm_cursor;
COMMIT;
SELECT calls, query FROM pg_stat_monitor ORDER BY query COLLATE "C";

SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
