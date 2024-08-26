CREATE EXTENSION pg_stat_monitor;
Set pg_stat_monitor.pgsm_normalized_query='off';

CREATE TABLE t1 (a TEXT, b TEXT, c TEXT);

SELECT pg_stat_monitor_reset();

-- First test, execute cheap query then heavy query.
-- Ensure denormalized heavy query replaces the cheaper one.
PREPARE prepstmt(TEXT, TEXT, TEXT) AS INSERT INTO t1(a, b, c) VALUES($1, $2, $3);

EXECUTE prepstmt('A', 'B', 'C');
SELECT SUBSTRING(query, 0, 128), calls FROM pg_stat_monitor ORDER BY query COLLATE "C";

EXECUTE prepstmt(REPEAT('XYZ', 8192), md5(random()::text), REPEAT('RANDOM', 4096));
SELECT SUBSTRING(query, 0, 128), calls FROM pg_stat_monitor ORDER BY query COLLATE "C";

TRUNCATE TABLE t1;
SELECT pg_stat_monitor_reset();

-- Second test, execute heavy query then cheap query.
-- Ensure denormalized heavy query is not replaced by the cheaper one.

EXECUTE prepstmt(REPEAT('XYZ', 8192), md5(random()::text), REPEAT('RANDOM', 4096));
SELECT SUBSTRING(query, 0, 128), calls FROM pg_stat_monitor ORDER BY query COLLATE "C";

EXECUTE prepstmt('A', 'B', 'C');
SELECT SUBSTRING(query, 0, 128), calls FROM pg_stat_monitor ORDER BY query COLLATE "C";

DROP TABLE t1;

SELECT pg_stat_monitor_reset();
DROP EXTENSION pg_stat_monitor;
