/* contrib/pg_stat_monitor/pg_stat_monitor--2.1--2.2.sql */

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
