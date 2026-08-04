CREATE EXTENSION pg_stat_monitor;
SELECT pg_stat_monitor_reset();

SELECT 1 AS num;
SET application_name = '';
SELECT 1 AS num;
SELECT query, application_name, application_name IS NULL AS isnull FROM pg_stat_monitor ORDER BY query, application_name COLLATE "C";
SELECT pg_stat_monitor_reset();

-- The parameter is deprecated and has no effect, but setting it must still
-- emit a deprecation warning.
SET pg_stat_monitor.pgsm_track_application_names = off;

DROP EXTENSION pg_stat_monitor;
