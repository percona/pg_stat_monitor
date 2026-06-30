CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();

CREATE FUNCTION test() RETURNS void AS $$
BEGIN
    PERFORM 1 + 2;
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION test2() RETURNS void AS $$
BEGIN
    PERFORM 1 + 2;
END
$$ LANGUAGE plpgsql;

SELECT pg_stat_monitor_reset(); 
SELECT test(); 
SELECT test2();  	

SELECT 1 + 2;
SELECT left(query, 15) AS query, calls, top_query, pgsm_query_id FROM pg_stat_monitor ORDER BY query, top_query COLLATE "C";

DROP EXTENSION pg_stat_monitor;
