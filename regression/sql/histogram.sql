CREATE FUNCTION generate_histogram() RETURNS TABLE (range text, freq int, bar text) AS $$
DECLARE
    bucket_id int;
    query_id int8;
BEGIN
    SELECT bucket, queryid INTO bucket_id, query_id FROM pg_stat_monitor ORDER BY calls DESC LIMIT 1;

    RETURN QUERY SELECT * FROM histogram(bucket_id, query_id) AS a (range text, freq int, bar text);
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION run_pg_sleep(loops int) RETURNS void AS $$
BEGIN
    FOR i IN 1..loops LOOP
        -- 0.4 seconds step used here to hit the same histogram buckets consistently.
        -- See histogram buckets timing distribution.
	   PERFORM pg_sleep(0.4 * i);
    END LOOP;
END
$$ LANGUAGE plpgsql;

CREATE FUNCTION wait_for_new_bucket() RETURNS void AS $$
BEGIN
    -- If the bucket lifetime is less than 8 seconds, we would not fit.
    IF extract(SECOND FROM now()) > 52 THEN
        PERFORM pg_sleep(60 - extract(SECOND FROM now()));
    END IF;
END
$$ LANGUAGE plpgsql;

CREATE EXTENSION pg_stat_monitor;
SELECT wait_for_new_bucket();
SELECT pg_stat_monitor_reset();
SET pg_stat_monitor.pgsm_track = 'all';
SELECT run_pg_sleep(5);

SELECT substr(query, 0, 50) as query, calls, resp_calls FROM pg_stat_monitor ORDER BY query COLLATE "C";

SELECT * FROM generate_histogram();

DROP EXTENSION pg_stat_monitor;
