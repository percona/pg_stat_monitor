CREATE EXTENSION pg_stat_monitor;
SELECT pg_stat_monitor_reset();

SELECT 1 AS num;
SELECT query, application_name FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

-- The parameter is deprecated and has no effect, but setting it must still
-- emit a deprecation warning.
SET pg_stat_monitor.pgsm_track_application_names = off;

DROP EXTENSION pg_stat_monitor;
