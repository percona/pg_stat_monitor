--
-- Validate WAL generation metrics
--

CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track_utility = off;
SET pg_stat_monitor.pgsm_normalized_query = on;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;

CREATE TABLE pgsm_wal_tab (a int, b char(20));

INSERT INTO pgsm_wal_tab VALUES(generate_series(1, 10), 'aaa');
UPDATE pgsm_wal_tab SET b = 'bbb' WHERE a > 7;
DELETE FROM pgsm_wal_tab WHERE a > 9;
DROP TABLE pgsm_wal_tab;

-- Check WAL is generated for the above statements
SELECT query, calls, rows,
    wal_bytes > 0 AS wal_bytes_generated,
    wal_records > 0 AS wal_records_generated,
    wal_records >= rows AS wal_records_ge_rows
FROM pg_stat_monitor ORDER BY query COLLATE "C";

SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
