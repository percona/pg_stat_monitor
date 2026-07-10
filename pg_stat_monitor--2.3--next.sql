-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_stat_monitor" to load this file. \quit

CREATE OR REPLACE FUNCTION decode_error_level(elevel int)
RETURNS text
STRICT
PARALLEL SAFE
LANGUAGE c
AS 'MODULE_PATHNAME', 'pg_stat_monitor_decode_error_level';

CREATE OR REPLACE FUNCTION get_cmd_type(cmd_type int)
RETURNS text
STRICT
PARALLEL SAFE
LANGUAGE c
AS 'MODULE_PATHNAME', 'pg_stat_monitor_get_cmd_type';

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
