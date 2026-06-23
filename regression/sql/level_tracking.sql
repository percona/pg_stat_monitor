--
-- Statement level tracking
--

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

--
-- pg_stat_monitor.pgsm_track = none
--
SET pg_stat_monitor.pgsm_track = 'none';
SELECT pg_stat_monitor_reset();

SELECT 1 AS one;
SELECT 1 + 1 AS two;

SELECT calls, rows, query FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

DROP EXTENSION pg_stat_monitor;
