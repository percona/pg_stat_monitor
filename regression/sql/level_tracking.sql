--
-- Statement level tracking
--

-- Some of the cases below need MERGE whose USING clause has an unaliased
-- sub-SELECT, which requires PostgreSQL 16+, and MERGE with a RETURNING
-- clause, which requires PostgreSQL 17+.  They are skipped on the older
-- versions instead of skipping the whole file.
SELECT setting::int >= 160000 AS have_merge,
       setting::int >= 170000 AS have_merge_returning
    FROM pg_settings WHERE name = 'server_version_num' \gset

CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track_utility = on;
SET pg_stat_monitor.pgsm_normalized_query = on;
SELECT pg_stat_monitor_reset();

-- DO block - top-level tracking.
CREATE TABLE stats_track_tab (x int);
SET pg_stat_monitor.pgsm_track = 'top';
DELETE FROM stats_track_tab;
DO $$
BEGIN
    DELETE FROM stats_track_tab;
END
$$;
SELECT toplevel, calls, query FROM pg_stat_monitor
    WHERE query LIKE '%DELETE%' ORDER BY query COLLATE "C", toplevel;
SELECT pg_stat_monitor_reset();

-- DO block - all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
DELETE FROM stats_track_tab;
DO $$
BEGIN
    DELETE FROM stats_track_tab;
END
$$;
DO $$
BEGIN
    -- this is a SELECT
    PERFORM 'hello world'::text;
END
$$;
SELECT toplevel, calls, query FROM pg_stat_monitor
    ORDER BY query COLLATE "C", toplevel;

-- Procedure with multiple utility statements.
CREATE OR REPLACE PROCEDURE proc_with_utility_stmt()
LANGUAGE SQL
AS $$
    SHOW pg_stat_monitor.pgsm_track;
    show pg_stat_monitor.pgsm_track;
    SHOW pg_stat_monitor.pgsm_track_utility;
$$;
SET pg_stat_monitor.pgsm_track_utility = on;
-- all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
CALL proc_with_utility_stmt();
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C", toplevel;
-- top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
CALL proc_with_utility_stmt();
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C", toplevel;

-- EXPLAIN - all-level tracking.
CREATE TABLE test_table (x int);
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
EXPLAIN (COSTS OFF) SELECT 1;
EXPLAIN (COSTS OFF) (SELECT 1, 2);
EXPLAIN (COSTS OFF) TABLE stats_track_tab;
EXPLAIN (COSTS OFF) (TABLE test_table);
EXPLAIN (COSTS OFF) VALUES (1);
EXPLAIN (COSTS OFF) (VALUES (1, 2));
EXPLAIN (COSTS OFF) UPDATE stats_track_tab SET x = 1 WHERE x = 1;
EXPLAIN (COSTS OFF) DELETE FROM stats_track_tab;
EXPLAIN (COSTS OFF) INSERT INTO stats_track_tab VALUES ((1));
\if :have_merge
EXPLAIN (COSTS OFF) MERGE INTO stats_track_tab
  USING (SELECT id FROM generate_series(1, 10) id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id);
\endif
EXPLAIN (COSTS OFF) SELECT 1 UNION SELECT 2;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- EXPLAIN - top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
EXPLAIN (COSTS OFF) SELECT 1;
EXPLAIN (COSTS OFF) (SELECT 1, 2);
EXPLAIN (COSTS OFF) TABLE stats_track_tab;
EXPLAIN (COSTS OFF) (TABLE test_table);
EXPLAIN (COSTS OFF) VALUES (1);
EXPLAIN (COSTS OFF) (VALUES (1, 2));
EXPLAIN (COSTS OFF) UPDATE stats_track_tab SET x = 1 WHERE x = 1;
EXPLAIN (COSTS OFF) DELETE FROM stats_track_tab;
EXPLAIN (COSTS OFF) INSERT INTO stats_track_tab VALUES ((1));
\if :have_merge
EXPLAIN (COSTS OFF) MERGE INTO stats_track_tab
  USING (SELECT id FROM generate_series(1, 10) id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id);
\endif
EXPLAIN (COSTS OFF) SELECT 1 UNION SELECT 2;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- EXPLAIN - all-level tracking with multi-statement strings.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
-- SELECT queries
EXPLAIN (COSTS OFF) SELECT 1\; EXPLAIN (COSTS OFF) SELECT 1, 2;
EXPLAIN (COSTS OFF) (SELECT 1, 2, 3)\; EXPLAIN (COSTS OFF) (SELECT 1, 2, 3, 4);
EXPLAIN (COSTS OFF) SELECT 1, 2 UNION SELECT 3, 4\; EXPLAIN (COSTS OFF) (SELECT 1, 2, 3) UNION SELECT 3, 4, 5;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();
-- Most DMLs
EXPLAIN (COSTS OFF) TABLE stats_track_tab\; EXPLAIN (COSTS OFF) (TABLE test_table);
EXPLAIN (COSTS OFF) VALUES (1)\; EXPLAIN (COSTS OFF) (VALUES (1, 2));
EXPLAIN (COSTS OFF) UPDATE stats_track_tab SET x = 1 WHERE x = 1\; EXPLAIN (COSTS OFF) UPDATE stats_track_tab SET x = 1;
EXPLAIN (COSTS OFF) DELETE FROM stats_track_tab\; EXPLAIN (COSTS OFF) DELETE FROM stats_track_tab WHERE x = 1;
EXPLAIN (COSTS OFF) INSERT INTO stats_track_tab VALUES ((1))\; EXPLAIN (COSTS OFF) INSERT INTO stats_track_tab VALUES (1), (2);
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();
-- MERGE, worth its own.
\if :have_merge
EXPLAIN (COSTS OFF) MERGE INTO stats_track_tab
  USING (SELECT id FROM generate_series(1, 10) id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id)\; EXPLAIN (COSTS OFF) SELECT 1, 2, 3, 4, 5;
\endif
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- EXPLAIN - top-level tracking with multi-statement strings.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
EXPLAIN (COSTS OFF) SELECT 1\; EXPLAIN (COSTS OFF) SELECT 1, 2;
EXPLAIN (COSTS OFF) (SELECT 1, 2, 3)\; EXPLAIN (COSTS OFF) (SELECT 1, 2, 3, 4);
EXPLAIN (COSTS OFF) TABLE stats_track_tab\; EXPLAIN (COSTS OFF) (TABLE test_table);
EXPLAIN (COSTS OFF) VALUES (1)\; EXPLAIN (COSTS OFF) (VALUES (1, 2));
EXPLAIN (COSTS OFF) UPDATE stats_track_tab SET x = 1 WHERE x = 1\; EXPLAIN (COSTS OFF) UPDATE stats_track_tab SET x = 1;
EXPLAIN (COSTS OFF) DELETE FROM stats_track_tab\; EXPLAIN (COSTS OFF) DELETE FROM stats_track_tab WHERE x = 1;
EXPLAIN (COSTS OFF) INSERT INTO stats_track_tab VALUES ((1))\; EXPLAIN (COSTS OFF) INSERT INTO stats_track_tab VALUES ((1), (2));
\if :have_merge
EXPLAIN (COSTS OFF) MERGE INTO stats_track_tab USING (SELECT id FROM generate_series(1, 10) id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id)\; EXPLAIN (COSTS OFF) SELECT 1, 2, 3, 4, 5;
\endif
EXPLAIN (COSTS OFF) SELECT 1, 2 UNION SELECT 3, 4\; EXPLAIN (COSTS OFF) (SELECT 1, 2, 3) UNION SELECT 3, 4, 5;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- EXPLAIN with CTEs - all-level tracking
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) SELECT 1;
EXPLAIN (COSTS OFF) (WITH a AS (SELECT 4) (SELECT 1, 2));
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) UPDATE stats_track_tab SET x = 1 WHERE x = 1;
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) DELETE FROM stats_track_tab;
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) INSERT INTO stats_track_tab VALUES ((1));
\if :have_merge
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) MERGE INTO stats_track_tab
  USING (SELECT id FROM generate_series(1, 10) id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id);
\endif
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) SELECT 1 UNION SELECT 2;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- EXPLAIN with CTEs - top-level tracking
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) SELECT 1;
EXPLAIN (COSTS OFF) (WITH a AS (SELECT 4) (SELECT 1, 2));
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) UPDATE stats_track_tab SET x = 1 WHERE x = 1;
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) DELETE FROM stats_track_tab;
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) INSERT INTO stats_track_tab VALUES ((1));
\if :have_merge
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) MERGE INTO stats_track_tab
  USING (SELECT id FROM generate_series(1, 10) id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id);
\endif
EXPLAIN (COSTS OFF) WITH a AS (SELECT 4) SELECT 1 UNION SELECT 2;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- Explain analyze, all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT 100;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
  DECLARE foocur CURSOR FOR SELECT * FROM stats_track_tab;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- Explain analyze, top tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF) SELECT 100;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF, BUFFERS OFF)
  DECLARE foocur CURSOR FOR SELECT * FROM stats_track_tab;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- Create Materialized View, all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
CREATE MATERIALIZED VIEW pgsm_materialized_view AS
  SELECT * FROM generate_series(1, 5) AS id;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- CREATE MATERIALIZED VIEW, top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
CREATE MATERIALIZED VIEW pgsm_materialized_view_2 AS
  SELECT * FROM generate_series(1, 5) AS id;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- REFRESH MATERIALIZED VIEW, all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
REFRESH MATERIALIZED VIEW pgsm_materialized_view;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- REFRESH MATERIALIZED VIEW, top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
REFRESH MATERIALIZED VIEW pgsm_materialized_view;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- CREATE TABLE AS, all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
PREPARE test_prepare_pgsm AS SELECT generate_series(1, 10);
SELECT pg_stat_monitor_reset();
CREATE TEMPORARY TABLE pgsm_ctas_1 AS SELECT 1;
CREATE TEMPORARY TABLE pgsm_ctas_2 AS EXECUTE test_prepare_pgsm;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- CREATE TABLE AS, top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
CREATE TEMPORARY TABLE pgsm_ctas_3 AS SELECT 1;
CREATE TEMPORARY TABLE pgsm_ctas_4 AS EXECUTE test_prepare_pgsm;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- EXPLAIN with CREATE TABLE AS - all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
EXPLAIN (COSTS OFF) CREATE TEMPORARY TABLE pgsm_explain_ctas AS SELECT 1;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- EXPLAIN with CREATE TABLE AS - top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
EXPLAIN (COSTS OFF) CREATE TEMPORARY TABLE pgsm_explain_ctas AS SELECT 1;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- DECLARE CURSOR, all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
BEGIN;
DECLARE FOOCUR CURSOR FOR SELECT * FROM stats_track_tab;
FETCH FORWARD 1 FROM foocur;
CLOSE foocur;
COMMIT;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- DECLARE CURSOR, top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
BEGIN;
DECLARE FOOCUR CURSOR FOR SELECT * FROM stats_track_tab;
FETCH FORWARD 1 FROM foocur;
CLOSE foocur;
COMMIT;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- COPY - all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
COPY (SELECT 1) TO stdout;
COPY (SELECT 1 UNION SELECT 2) TO stdout;
\if :have_merge_returning
COPY (MERGE INTO stats_track_tab USING (SELECT 1 id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id) RETURNING x) TO stdout;
\endif
COPY (INSERT INTO stats_track_tab (x) VALUES (1) RETURNING x) TO stdout;
COPY (UPDATE stats_track_tab SET x = 2 WHERE x = 1 RETURNING x) TO stdout;
COPY (DELETE FROM stats_track_tab WHERE x = 2 RETURNING x) TO stdout;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- COPY - top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SELECT pg_stat_monitor_reset();
COPY (SELECT 1) TO stdout;
COPY (SELECT 1 UNION SELECT 2) TO stdout;
\if :have_merge_returning
COPY (MERGE INTO stats_track_tab USING (SELECT 1 id) ON x = id
  WHEN MATCHED THEN UPDATE SET x = id
  WHEN NOT MATCHED THEN INSERT (x) VALUES (id) RETURNING x) TO stdout;
\endif
COPY (INSERT INTO stats_track_tab (x) VALUES (1) RETURNING x) TO stdout;
COPY (UPDATE stats_track_tab SET x = 2 WHERE x = 1 RETURNING x) TO stdout;
COPY (DELETE FROM stats_track_tab WHERE x = 2 RETURNING x) TO stdout;
SELECT toplevel, calls, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

-- DO block - top-level tracking without utility.
SET pg_stat_monitor.pgsm_track = 'top';
SET pg_stat_monitor.pgsm_track_utility = off;
SELECT pg_stat_monitor_reset();
DELETE FROM stats_track_tab;
DO $$
BEGIN
    DELETE FROM stats_track_tab;
END
$$;
DO $$
BEGIN
    -- this is a SELECT
    PERFORM 'hello world'::text;
END
$$;
SELECT toplevel, calls, query FROM pg_stat_monitor
    ORDER BY query COLLATE "C", toplevel;

-- DO block - all-level tracking without utility.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
DELETE FROM stats_track_tab;
DO $$
BEGIN
    DELETE FROM stats_track_tab;
END
$$;
DO $$
BEGIN
    -- this is a SELECT
    PERFORM 'hello world'::text;
END
$$;
SELECT toplevel, calls, query FROM pg_stat_monitor
    ORDER BY query COLLATE "C", toplevel;

-- DO block --- multiple inner queries with separators
SET pg_stat_monitor.pgsm_track = 'all';
SET pg_stat_monitor.pgsm_track_utility = on;
CREATE TABLE pgsm_do_util_tab_1 (a int);
CREATE TABLE pgsm_do_util_tab_2 (a int);
SELECT pg_stat_monitor_reset();
DO $$
DECLARE BEGIN
    EXECUTE 'CREATE TABLE pgsm_do_table (id INT); DROP TABLE pgsm_do_table';
    EXECUTE 'SELECT a FROM pgsm_do_util_tab_1; SELECT a FROM pgsm_do_util_tab_2';
END $$;
SELECT toplevel, calls, rows, query FROM pg_stat_monitor
  WHERE toplevel IS FALSE
  ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();
-- Note the extra semicolon at the end of the query.
DO $$
DECLARE BEGIN
    EXECUTE 'CREATE TABLE pgsm_do_table (id INT); DROP TABLE pgsm_do_table;';
    EXECUTE 'SELECT a FROM pgsm_do_util_tab_1; SELECT a FROM pgsm_do_util_tab_2;';
END $$;
SELECT toplevel, calls, rows, query FROM pg_stat_monitor
  WHERE toplevel IS FALSE
  ORDER BY query COLLATE "C";
DROP TABLE pgsm_do_util_tab_1, pgsm_do_util_tab_2;

-- PL/pgSQL function - top-level tracking.
SET pg_stat_monitor.pgsm_track = 'top';
SET pg_stat_monitor.pgsm_track_utility = off;
SELECT pg_stat_monitor_reset();
CREATE FUNCTION plus_two(i int) RETURNS int AS $$
DECLARE
    r int;
BEGIN
    SELECT (i + 1 + 1.0)::int INTO r;
    RETURN r;
END
$$ LANGUAGE plpgsql;

SELECT plus_two(3);
SELECT plus_two(7);

-- SQL function --- use LIMIT to keep it from being inlined
CREATE FUNCTION plus_one(i int) RETURNS int AS
$$ SELECT (i + 1.0)::int LIMIT 1 $$ LANGUAGE sql;

SELECT plus_one(8);
SELECT plus_one(10);

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";

-- immutable SQL function --- can be executed at plan time
CREATE FUNCTION plus_three(i int) RETURNS int AS
$$ SELECT i + 3 LIMIT 1 $$ IMMUTABLE LANGUAGE sql;

SELECT plus_three(8);
SELECT plus_three(10);

SELECT toplevel, calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";

-- PL/pgSQL function - all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();

-- we drop and recreate the functions to avoid any caching funnies
DROP FUNCTION plus_one(int);
DROP FUNCTION plus_two(int);
DROP FUNCTION plus_three(int);

-- PL/pgSQL function
CREATE FUNCTION plus_two(i int) RETURNS int AS $$
DECLARE
    r int;
BEGIN
    SELECT (i + 1 + 1.0)::int INTO r;
    RETURN r;
END
$$ LANGUAGE plpgsql;

SELECT plus_two(-1);
SELECT plus_two(2);

-- SQL function --- use LIMIT to keep it from being inlined
CREATE FUNCTION plus_one(i int) RETURNS int AS
$$ SELECT (i + 1.0)::int LIMIT 1 $$ LANGUAGE sql;

SELECT plus_one(3);
SELECT plus_one(1);

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";

-- immutable SQL function --- can be executed at plan time
CREATE FUNCTION plus_three(i int) RETURNS int AS
$$ SELECT i + 3 LIMIT 1 $$ IMMUTABLE LANGUAGE sql;

SELECT plus_three(8);
SELECT plus_three(10);

SELECT toplevel, calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

-- planner - all-level tracking.
SET pg_stat_monitor.pgsm_track_planning = on;
-- Release all cached plans before the first function call.  This matters
-- when debug_discard_caches is enabled, which would store a normalized
-- version of the inner query of the function.  Forcing a plan rebuild
-- ensures that a normalized version is always stored with the stats entry,
-- while checking that the nesting level is computed correctly in the
-- planner hook.
DISCARD PLANS;
SELECT plus_three(8);
SELECT plus_three(10);

SELECT toplevel, calls, rows, plans, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";
RESET pg_stat_monitor.pgsm_track_planning;

-- AFTER trigger SQL (ExecutorFinish) - all-level tracking.
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();

CREATE TABLE test_trigger (id int, name text);
CREATE TABLE audit_table (table_name text, action text, row_id int);
CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO audit_table VALUES ('test_trigger', TG_OP, NEW.id);
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER audit_after_trigger
  AFTER INSERT ON test_trigger
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

INSERT INTO test_trigger VALUES (1, 'test1');
INSERT INTO test_trigger VALUES (2, 'test2');

SELECT toplevel, calls, rows, plans, query FROM pg_stat_monitor
  ORDER BY query COLLATE "C";

DROP TRIGGER audit_after_trigger ON test_trigger;
DROP FUNCTION audit_trigger_func();
DROP TABLE audit_table, test_trigger;

--
-- pg_stat_monitor.pgsm_track = none
--
SET pg_stat_monitor.pgsm_track = 'none';
SELECT pg_stat_monitor_reset();

SELECT 1 AS one;
SELECT 1 + 1 AS two;

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

DROP MATERIALIZED VIEW pgsm_materialized_view;
DROP MATERIALIZED VIEW pgsm_materialized_view_2;
DROP PROCEDURE proc_with_utility_stmt();
DEALLOCATE test_prepare_pgsm;
DROP TABLE stats_track_tab, test_table;

DROP EXTENSION pg_stat_monitor;
