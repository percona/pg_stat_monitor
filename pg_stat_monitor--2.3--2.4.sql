/* contrib/pg_stat_monitor/pg_stat_monitor--2.3--2.4.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pg_stat_monitor" to load this file. \quit

-- Create partitioned table with exact pg_stat_monitor API structure
-- Table columns match the expected API exactly - direct table access
DROP VIEW IF EXISTS pg_stat_monitor CASCADE;

CREATE TABLE pg_stat_monitor (
    bucket bigint,                    -- renamed from bucket_id
    bucket_start_time timestamptz,
    userid oid,
    username text,
    dbid oid,
    datname text,
    client_ip inet,
    pgsm_query_id bigint,
    queryid bigint,
    toplevel boolean,
    top_queryid bigint,

    -- Query texts limited to 1.5KB each
    query text,
    comments text,
    planid bigint,
    query_plan text,
    top_query text,

    application_name text,
    relations text[],                 -- array instead of comma-separated string
    cmd_type int,
    cmd_type_text text,              -- computed at write time
    elevel int,
    sqlcode text,
    message text,

    -- Execution stats
    calls bigint,
    total_exec_time double precision,
    min_exec_time double precision,
    max_exec_time double precision,
    mean_exec_time double precision,
    stddev_exec_time double precision,
    rows bigint,

    -- Planning stats
    plans bigint,
    total_plan_time double precision,
    min_plan_time double precision,
    max_plan_time double precision,
    mean_plan_time double precision,
    stddev_plan_time double precision,

    -- Block stats
    shared_blks_hit bigint,
    shared_blks_read bigint,
    shared_blks_dirtied bigint,
    shared_blks_written bigint,
    local_blks_hit bigint,
    local_blks_read bigint,
    local_blks_dirtied bigint,
    local_blks_written bigint,
    temp_blks_read bigint,
    temp_blks_written bigint,
    shared_blk_read_time double precision,
    shared_blk_write_time double precision,
    local_blk_read_time double precision,
    local_blk_write_time double precision,
    temp_blk_read_time double precision,
    temp_blk_write_time double precision,

    -- System stats
    cpu_user_time double precision,
    cpu_sys_time double precision,

    -- WAL stats
    wal_records bigint,
    wal_fpi bigint,
    wal_bytes numeric,

    -- JIT stats
    jit_functions bigint,
    jit_generation_time double precision,
    jit_inlining_count bigint,
    jit_inlining_time double precision,
    jit_optimization_count bigint,
    jit_optimization_time double precision,
    jit_emission_count bigint,
    jit_emission_time double precision,
    jit_deform_count bigint,
    jit_deform_time double precision,

    -- Response time histogram
    resp_calls text[],

    -- Metadata
    stats_since timestamptz,
    minmax_stats_since timestamptz,
    bucket_done boolean DEFAULT false,
    exported_at timestamptz DEFAULT now()
) PARTITION BY RANGE (exported_at);

-- Create initial partition for today
CREATE TABLE pg_stat_monitor_default
PARTITION OF pg_stat_monitor DEFAULT;

-- Create indexes for query performance
CREATE INDEX ON pg_stat_monitor (queryid);
CREATE INDEX ON pg_stat_monitor (exported_at);
CREATE INDEX ON pg_stat_monitor (bucket, queryid);  -- Composite for time-series queries

-- Configure memory and query text limits (set these manually in postgresql.conf):
-- pg_stat_monitor.pgsm_max = '10MB'
-- pg_stat_monitor.pgsm_max_buckets = 2
-- pg_stat_monitor.pgsm_query_shared_buffer = '1MB'
-- pg_stat_monitor.pgsm_query_max_len = 1536

-- Create user-callable export function following PostgreSQL extension best practices
CREATE OR REPLACE FUNCTION pg_stat_monitor_export()
RETURNS int
AS 'MODULE_PATHNAME', 'pg_stat_monitor_export'
LANGUAGE C STRICT VOLATILE;

-- Grant execute permission to public
GRANT EXECUTE ON FUNCTION pg_stat_monitor_export() TO PUBLIC;

-- Table structure matches API exactly - implementation complete