CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track='all';
SELECT pg_stat_monitor_reset();
CREATE OR REPLACE FUNCTION add(int, int) RETURNS INTEGER AS
$$
BEGIN
	return (select $1 + $2);
END; $$ language plpgsql;

CREATE OR REPLACE FUNCTION add2(int, int) RETURNS INTEGER AS
$$
BEGIN
	return add($1,$2);
END;
$$ language plpgsql;

SELECT add2(1,2);
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
END;
$$;

COMMIT;

SELECT pg_stat_monitor_reset();
DROP EXTENSION pg_stat_monitor;
