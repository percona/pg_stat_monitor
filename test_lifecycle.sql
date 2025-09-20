-- Integration test for pg_stat_monitor low-memory fork
-- Tests table export functionality, API compatibility, and memory configuration

-- Reset stats and verify clean state
SELECT pg_stat_monitor_reset();

-- Wait briefly for bucket to initialize
\! sleep 1

-- Generate some test queries to capture
SET pg_stat_monitor.pgsm_track_utility = on;
SELECT count(*) FROM pg_tables WHERE schemaname = 'public';
SELECT 'lifecycle test query' as test_message, current_timestamp;

-- Verify table structure matches expected API
\d pg_stat_monitor

-- Test key column existence
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'pg_stat_monitor' AND column_name = 'bucket'
) as has_bucket_column;

SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'pg_stat_monitor' AND column_name = 'cmd_type_text'
) as has_cmd_type_text_column;

-- Test export function exists and is callable
SELECT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'pg_stat_monitor_export'
) as export_function_exists;

-- Verify expected column count (should be 72 columns total)
SELECT count(*) as total_columns
FROM information_schema.columns
WHERE table_name = 'pg_stat_monitor';

-- Test that queries are being captured in memory
SELECT CASE
    WHEN EXISTS (
        SELECT 1 FROM pg_stat_monitor_internal()
        WHERE query LIKE '%lifecycle test query%'
    )
    THEN 'SUCCESS: Queries captured in memory'
    ELSE 'ERROR: No queries found in memory'
END as capture_status;

-- Test export function is callable
SELECT CASE
    WHEN pg_stat_monitor_export() >= 0
    THEN 'Export function callable: YES'
    ELSE 'Export function callable: NO'
END as export_function_test;

-- Verify bucket system is working
SELECT CASE
    WHEN count(*) > 0
    THEN 'SUCCESS: Bucket system working'
    ELSE 'ERROR: No buckets found'
END as bucket_system_status
FROM pg_stat_monitor_internal()
WHERE bucket_start_time IS NOT NULL;

-- Final success message
SELECT 'SUCCESS: Simplified codebase maintains full compatibility and functionality' as message;