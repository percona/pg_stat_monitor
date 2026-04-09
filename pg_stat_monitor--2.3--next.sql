-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_stat_monitor" to load this file. \quit

-- Drop PostgreSQL 13 support from function
CREATE OR REPLACE FUNCTION decode_error_level(elevel int)
RETURNS text
PARALLEL SAFE
LANGUAGE sql
AS $$
SELECT CASE
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
$$;

DROP FUNCTION pgsm_create_13_view();
DROP VIEW pg_stat_monitor;

CREATE OR REPLACE FUNCTION pgsm_create_view()
RETURNS int
LANGUAGE plpgsql
AS $$
    DECLARE ver integer;
    BEGIN
        SELECT current_setting('server_version_num') INTO ver;
    IF (ver >= 180000) THEN
        return pgsm_create_18_view();
    END IF;
    IF (ver >= 170000) THEN
        return pgsm_create_17_view();
    END IF;
    IF (ver >= 150000) THEN
        return pgsm_create_15_view();
    END IF;
    IF (ver >= 140000) THEN
        return pgsm_create_14_view();
    END IF;
    RETURN 0;
    END;
$$;

SELECT pgsm_create_view();
REVOKE ALL ON FUNCTION pgsm_create_view FROM PUBLIC;

GRANT SELECT ON pg_stat_monitor TO PUBLIC;
