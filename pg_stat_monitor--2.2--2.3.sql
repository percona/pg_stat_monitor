-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_stat_monitor" to load this file. \quit

DROP FUNCTION pgsm_create_11_view();
DROP VIEW pg_stat_monitor;
DROP FUNCTION pg_stat_monitor_internal;

CREATE FUNCTION pg_stat_monitor_internal(
    IN showtext             boolean,
    OUT bucket              int8,   -- 0
    OUT userid              oid,
    OUT username            text,
    OUT dbid                oid,
    OUT datname             text,
    OUT client_ip           int8,

    OUT queryid             int8,  -- 6
    OUT planid              int8,
    OUT query               text,
    OUT query_plan          text,
    OUT pgsm_query_id       int8,
    OUT top_queryid         int8,
    OUT top_query           text,
    OUT application_name    text,

    OUT relations           text, -- 14
    OUT cmd_type            int,
    OUT elevel              int,
    OUT sqlcode             TEXT,
    OUT message             text,
    OUT bucket_start_time   timestamptz,

    OUT calls               int8,  -- 20

    OUT total_exec_time     float8, -- 21
    OUT min_exec_time       float8,
    OUT max_exec_time       float8,
    OUT mean_exec_time      float8,
    OUT stddev_exec_time    float8,

    OUT rows                int8, -- 26

    OUT plans               int8,  -- 27

    OUT total_plan_time     float8, -- 28
    OUT min_plan_time       float8,
    OUT max_plan_time       float8,
    OUT mean_plan_time      float8,
    OUT stddev_plan_time    float8,

    OUT shared_blks_hit            int8, -- 33
    OUT shared_blks_read           int8,
    OUT shared_blks_dirtied        int8,
    OUT shared_blks_written        int8,
    OUT local_blks_hit             int8,
    OUT local_blks_read            int8,
    OUT local_blks_dirtied         int8,
    OUT local_blks_written         int8,
    OUT temp_blks_read             int8,
    OUT temp_blks_written          int8,
    OUT shared_blk_read_time       float8,
    OUT shared_blk_write_time      float8,
    OUT local_blk_read_time        float8,
    OUT local_blk_write_time       float8,
    OUT temp_blk_read_time         float8,
    OUT temp_blk_write_time        float8,

    OUT resp_calls          text, -- 49
    OUT cpu_user_time       float8,
    OUT cpu_sys_time        float8,
    OUT wal_records         int8,
    OUT wal_fpi             int8,
    OUT wal_bytes           numeric,
    OUT wal_buffers_full    int8,
    OUT comments            TEXT,

    OUT jit_functions           int8, -- 57
    OUT jit_generation_time     float8,
    OUT jit_inlining_count      int8,
    OUT jit_inlining_time       float8,
    OUT jit_optimization_count  int8,
    OUT jit_optimization_time   float8,
    OUT jit_emission_count      int8,
    OUT jit_emission_time       float8,
    OUT jit_deform_count        int8,
    OUT jit_deform_time         float8,

    OUT parallel_workers_to_launch  int, -- 67
    OUT parallel_workers_launched   int,

    OUT stats_since          timestamp with time zone, -- 69
    OUT minmax_stats_since   timestamp with time zone,

    OUT toplevel            BOOLEAN, -- 71
    OUT bucket_done         BOOLEAN
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_monitor_2_3'
LANGUAGE C STRICT VOLATILE PARALLEL SAFE;

CREATE FUNCTION pgsm_create_18_view() RETURNS INT AS
$$
BEGIN
CREATE VIEW pg_stat_monitor AS SELECT
    bucket,
    bucket_start_time,
    userid,
    username,
    dbid,
    datname,
    '0.0.0.0'::inet + client_ip AS client_ip,
    pgsm_query_id,
    queryid,
    toplevel,
    top_queryid,
    query,
    comments,
    planid,
    query_plan,
    top_query,
    application_name,
    string_to_array(relations, ',') AS relations,
    cmd_type,
    get_cmd_type(cmd_type) AS cmd_type_text,
    elevel,
    sqlcode,
    message,
    calls,
    total_exec_time,
    min_exec_time,
    max_exec_time,
    mean_exec_time,
    stddev_exec_time,
    rows,
    shared_blks_hit,
    shared_blks_read,
    shared_blks_dirtied,
    shared_blks_written,
    local_blks_hit,
    local_blks_read,
    local_blks_dirtied,
    local_blks_written,
    temp_blks_read,
    temp_blks_written,
    shared_blk_read_time,
    shared_blk_write_time,
    local_blk_read_time,
    local_blk_write_time,
    temp_blk_read_time,
    temp_blk_write_time,

    (string_to_array(resp_calls, ',')) resp_calls,
    cpu_user_time,
    cpu_sys_time,
    wal_records,
    wal_fpi,
    wal_bytes,
    wal_buffers_full,
    bucket_done,

    plans,
    total_plan_time,
    min_plan_time,
    max_plan_time,
    mean_plan_time,
    stddev_plan_time,

    jit_functions,
    jit_generation_time,
    jit_inlining_count,
    jit_inlining_time,
    jit_optimization_count,
    jit_optimization_time,
    jit_emission_count,
    jit_emission_time,
    jit_deform_count,
    jit_deform_time,

    parallel_workers_to_launch,
    parallel_workers_launched,

    stats_since,
    minmax_stats_since

FROM pg_stat_monitor_internal(TRUE)
ORDER BY bucket_start_time;
RETURN 0;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgsm_create_view() RETURNS INT AS
$$
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
    IF (ver >= 130000) THEN
        return pgsm_create_13_view();
    END IF;
    RETURN 0;
    END;
$$ LANGUAGE plpgsql;

SELECT pgsm_create_view();
REVOKE ALL ON FUNCTION pgsm_create_view FROM PUBLIC;
REVOKE ALL ON FUNCTION pgsm_create_18_view FROM PUBLIC;

GRANT SELECT ON pg_stat_monitor TO PUBLIC;
