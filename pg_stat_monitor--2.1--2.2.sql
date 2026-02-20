-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_stat_monitor" to load this file. \quit

CREATE OR REPLACE FUNCTION get_cmd_type (cmd_type INTEGER) RETURNS TEXT AS
$$
SELECT
    CASE
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
    END
$$
LANGUAGE SQL PARALLEL SAFE;

-- Create new function that handles error levels across PostgreSQL versions 12-17
CREATE OR REPLACE FUNCTION decode_error_level(elevel int)
RETURNS text
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
    WHEN elevel = 20 AND current_setting('server_version_num')::int < 140000 THEN 'ERROR'
    WHEN elevel = 20 AND current_setting('server_version_num')::int >= 140000 THEN 'WARNING_CLIENT_ONLY'
    WHEN elevel = 21 AND current_setting('server_version_num')::int < 140000 THEN 'FATAL'
    WHEN elevel = 21 AND current_setting('server_version_num')::int >= 140000 THEN 'ERROR'
    WHEN elevel = 22 AND current_setting('server_version_num')::int < 140000 THEN 'PANIC'
    WHEN elevel = 22 AND current_setting('server_version_num')::int >= 140000 THEN 'FATAL'
    WHEN elevel = 23 AND current_setting('server_version_num')::int >= 140000 THEN 'PANIC'
END;
$$ LANGUAGE SQL PARALLEL SAFE;
