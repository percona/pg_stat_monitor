CREATE OR REPLACE FUNCTION generate_histogram()
    RETURNS TABLE (
    RANGE TEXT, freq INT, bar TEXT
  )  AS $$
DECLARE
    bucket_id integer;
    query_id int8;
BEGIN
    SELECT bucket, queryid INTO bucket_id, query_id FROM pg_stat_monitor ORDER BY calls DESC LIMIT 1;
    -- RAISE INFO 'bucket_id %', bucket_id;
    -- RAISE INFO 'query_id %', query_id;
    RETURN query
    SELECT * FROM histogram(bucket_id, query_id) AS a(range TEXT, freq INT, bar TEXT);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION run_pg_sleep(INTEGER) RETURNS VOID AS $$
DECLARE
    loops ALIAS FOR $1;
BEGIN
    FOR i IN 1..loops LOOP
	-- RAISE INFO 'Current timestamp: %', timeofday()::TIMESTAMP;
    -- 0.4 seconds step used here to hit the same histogram buckets consistently.
    -- See histogram buckets timing distribution.
	PERFORM pg_sleep(0.4 * i);
    END LOOP;
END;
$$ LANGUAGE 'plpgsql' STRICT;

CREATE OR REPLACE FUNCTION wait_for_new_bucket() RETURNS VOID AS $$
DECLARE
    bucket_left_time int;
BEGIN
    -- This test works correctly only if the bucket duration is default (60 seconds).
    SELECT 60 - EXTRACT(
        SECOND FROM(
            SELECT CURRENT_TIMESTAMP(0) bucket_start_time FROM pg_stat_monitor ORDER BY bucket_start_time DESC LIMIT 1
        )
    )::int INTO bucket_left_time; 

    -- If the bucket lifetime is less than 10 seconds, we would not fit.
    IF bucket_left_time <= 4 THEN
        -- RAISE NOTICE 'Bucket lifetime comes to an end → sleeping 4 seconds...';
        PERFORM pg_sleep(4);
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE EXTENSION pg_stat_monitor;
SELECT wait_for_new_bucket();
SELECT pg_stat_monitor_reset();
SET pg_stat_monitor.pgsm_track='all';
SELECT run_pg_sleep(5);

SELECT substr(query, 0, 50) as query, calls, resp_calls FROM pg_stat_monitor ORDER BY query COLLATE "C";

SELECT * FROM generate_histogram();

DROP EXTENSION pg_stat_monitor;
