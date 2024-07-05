CREATE EXTENSION pg_stat_monitor;
SELECT pg_stat_monitor_reset();

SELECT 1 AS num;
SELECT query,application_name FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

SET pg_stat_monitor.pgsm_track_application_names='TRUE';
SELECT 1 AS num;
SELECT query,application_name FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

DROP EXTENSION pg_stat_monitor;
