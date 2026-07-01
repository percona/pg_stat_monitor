-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_stat_monitor" to load this file. \quit

-- Drop PostgreSQL 13 support from function
CREATE OR REPLACE FUNCTION decode_error_level(elevel int)
RETURNS text
PARALLEL SAFE
LANGUAGE sql
RETURN CASE
    WHEN elevel = 0 THEN ''
    WHEN elevel = 10 THEN 'DEBUG5'
    WHEN elevel = 11 THEN 'DEBUG4'
    WHEN elevel = 12 THEN 'DEBUG3'
    WHEN elevel = 13 THEN 'DEBUG2'
    WHEN elevel = 14 THEN 'DEBUG1'
    WHEN elevel = 15 THEN 'LOG'
    WHEN elevel = 16 THEN 'LOG_SERVER_ONLY'
    WHEN elevel = 17 THEN 'INFO'
    WHEN elevel = 18 THEN 'NOTICE'
    WHEN elevel = 19 THEN 'WARNING'
    WHEN elevel = 20 THEN 'WARNING_CLIENT_ONLY'
    WHEN elevel = 21 THEN 'ERROR'
    WHEN elevel = 22 THEN 'FATAL'
    WHEN elevel = 23 THEN 'PANIC'
END;

CREATE OR REPLACE FUNCTION get_cmd_type(cmd_type int)
RETURNS text
PARALLEL SAFE
LANGUAGE sql
RETURN CASE
    WHEN cmd_type = 0 THEN ''
    WHEN cmd_type = 1 THEN 'SELECT'
    WHEN cmd_type = 2 THEN 'UPDATE'
    WHEN cmd_type = 3 THEN 'INSERT'
    WHEN cmd_type = 4 THEN 'DELETE'
    WHEN cmd_type = 5 AND current_setting('server_version_num')::int >= 150000 THEN 'MERGE'
    WHEN cmd_type = 5 AND current_setting('server_version_num')::int < 150000 THEN 'UTILITY'
    WHEN cmd_type = 6 AND current_setting('server_version_num')::int >= 150000 THEN 'UTILITY'
    WHEN cmd_type = 6 AND current_setting('server_version_num')::int < 150000 THEN 'NOTHING'
    WHEN cmd_type = 7 THEN 'NOTHING'
END;

CREATE OR REPLACE FUNCTION range()
RETURNS text[]
LANGUAGE sql
RETURN string_to_array(get_histogram_timings(), ',');

-- Intentionally uses a string body so we can drop and recreate the pg_stat_monitor view
CREATE OR REPLACE FUNCTION histogram(_bucket int, _quryid int8)
RETURNS SETOF record
LANGUAGE sql
AS $$
WITH stat AS (
    SELECT
        queryid,
        bucket,
        unnest(range()) AS range,
        unnest(resp_calls)::int AS freq
    FROM pg_stat_monitor
)
SELECT
    range,
    freq,
    repeat('■', (freq::float / max(freq) OVER () * 30)::int) AS bar
FROM stat
WHERE queryid = _quryid AND bucket = _bucket
$$;

DROP FUNCTION pgsm_create_13_view();
DROP VIEW pg_stat_monitor;

CREATE OR REPLACE FUNCTION pgsm_create_view()
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
    version int := current_setting('server_version_num');
BEGIN
    IF version >= 180000 THEN
        RETURN pgsm_create_18_view();
    ELSEIF version >= 170000 THEN
        RETURN pgsm_create_17_view();
    ELSEIF version >= 150000 THEN
        RETURN pgsm_create_15_view();
    ELSEIF version >= 140000 THEN
        RETURN pgsm_create_14_view();
    END IF;
    RETURN 0;
END;
$$;

SELECT pgsm_create_view();
REVOKE ALL ON FUNCTION pgsm_create_view FROM PUBLIC;

GRANT SELECT ON pg_stat_monitor TO PUBLIC;
