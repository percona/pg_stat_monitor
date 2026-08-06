--
-- DMLs on test table
--

-- MERGE requires PostgreSQL 15+.
SELECT setting::int < 150000 AS skip_test FROM pg_settings where name = 'server_version_num' \gset
\if :skip_test
\quit
\endif

CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track_utility = off;
SET pg_stat_monitor.pgsm_normalized_query = on;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;

CREATE TEMP TABLE pgsm_dml_tab (a int, b char(20));

INSERT INTO pgsm_dml_tab VALUES(generate_series(1, 10), 'aaa');
UPDATE pgsm_dml_tab SET b = 'bbb' WHERE a > 7;
DELETE FROM pgsm_dml_tab WHERE a > 9;

-- explicit transaction
BEGIN;
UPDATE pgsm_dml_tab SET b = '111' WHERE a = 1 ;
COMMIT;

BEGIN \;
UPDATE pgsm_dml_tab SET b = '222' WHERE a = 2 \;
COMMIT ;

UPDATE pgsm_dml_tab SET b = '333' WHERE a = 3 \;
UPDATE pgsm_dml_tab SET b = '444' WHERE a = 4 ;

BEGIN \;
UPDATE pgsm_dml_tab SET b = '555' WHERE a = 5 \;
UPDATE pgsm_dml_tab SET b = '666' WHERE a = 6 \;
COMMIT ;

-- many INSERT values
INSERT INTO pgsm_dml_tab (a, b) VALUES (1, 'a'), (2, 'b'), (3, 'c');

-- SELECT with constants
SELECT * FROM pgsm_dml_tab WHERE a > 5 ORDER BY a ;

SELECT *
    FROM pgsm_dml_tab
    WHERE a > 9
    ORDER BY a ;

-- these two need to be done on a different table
-- SELECT without constants
SELECT * FROM pgsm_dml_tab ORDER BY a;

-- SELECT with IN clause
SELECT * FROM pgsm_dml_tab WHERE a IN (1, 2, 3, 4, 5);

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;

-- MERGE
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a AND st.a >= 4)
    WHEN MATCHED THEN UPDATE SET b = st.b || st.a::text;
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a AND st.a >= 4)
    WHEN MATCHED THEN UPDATE SET b = pgsm_dml_tab.b || st.a::text;
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a AND st.a >= 4)
    WHEN MATCHED AND length(st.b) > 1 THEN UPDATE SET b = pgsm_dml_tab.b || st.a::text;
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a)
    WHEN NOT MATCHED THEN INSERT (a, b) VALUES (0, NULL);
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a)
    WHEN NOT MATCHED THEN INSERT VALUES (0, NULL);	-- same as above
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a)
    WHEN NOT MATCHED THEN INSERT (b, a) VALUES (NULL, 0);
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a)
    WHEN NOT MATCHED THEN INSERT (a) VALUES (0);
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a AND st.a >= 4)
    WHEN MATCHED THEN DELETE;
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a AND st.a >= 4)
    WHEN MATCHED THEN DO NOTHING;
MERGE INTO pgsm_dml_tab USING pgsm_dml_tab st ON (st.a = pgsm_dml_tab.a AND st.a >= 4)
    WHEN NOT MATCHED THEN DO NOTHING;

DROP TABLE pgsm_dml_tab;

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";

-- check that [temp] table relation extensions are tracked as writes
CREATE TABLE pgsm_extend_tab (a int, b text);
CREATE TEMP TABLE pgsm_extend_temp_tab (a int, b text);
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
INSERT INTO pgsm_extend_tab (a, b) SELECT generate_series(1, 1000), 'something';
INSERT INTO pgsm_extend_temp_tab (a, b) SELECT generate_series(1, 1000), 'something';
WITH sizes AS (
    SELECT
        pg_relation_size('pgsm_extend_tab') / current_setting('block_size')::int8 AS rel_size,
        pg_relation_size('pgsm_extend_temp_tab') / current_setting('block_size')::int8 AS temp_rel_size
)
SELECT
    SUM(local_blks_written) >= (SELECT temp_rel_size FROM sizes) AS temp_written_ok,
    SUM(local_blks_dirtied) >= (SELECT temp_rel_size FROM sizes) AS temp_dirtied_ok,
    SUM(shared_blks_written) >= (SELECT rel_size FROM sizes) AS written_ok,
    SUM(shared_blks_dirtied) >= (SELECT rel_size FROM sizes) AS dirtied_ok
FROM pg_stat_monitor;

DROP TABLE pgsm_extend_tab;
DROP TABLE pgsm_extend_temp_tab;

SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
