CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();
CREATE FUNCTION add(int, int) RETURNS int AS
$$
BEGIN
    RETURN (SELECT $1 + $2);
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION add2(int, int) RETURNS int AS
$$
BEGIN
    RETURN add($1, $2);
END
$$ LANGUAGE plpgsql;

SELECT add2(1, 2);
SELECT query, top_query FROM pg_stat_monitor ORDER BY query COLLATE "C";

-- make sure that we handle nested queries correctly

BEGIN;

DO $$
DECLARE
    i int;
BEGIN
    -- default stack limit is 2000kB, 50000 is much larger than that
    FOR i IN 1..50000 LOOP
        EXECUTE format('SELECT %s', i);
    END LOOP;
END
$$;

COMMIT;

SELECT pg_stat_monitor_reset();
DROP EXTENSION pg_stat_monitor;
