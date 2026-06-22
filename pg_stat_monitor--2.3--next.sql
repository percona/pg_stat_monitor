-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_stat_monitor" to load this file. \quit

CREATE OR REPLACE FUNCTION decode_error_level(elevel int)
RETURNS text
PARALLEL SAFE
LANGUAGE c
AS 'MODULE_PATHNAME', 'pg_stat_monitor_decode_error_level';

CREATE OR REPLACE FUNCTION get_cmd_type(cmd_type int)
RETURNS text
PARALLEL SAFE
LANGUAGE c
AS 'MODULE_PATHNAME', 'pg_stat_monitor_get_cmd_type';

CREATE OR REPLACE FUNCTION range()
RETURNS text[]
LANGUAGE sql
RETURN string_to_array(get_histogram_timings(), ',');

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
