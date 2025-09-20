# pg_stat_monitor Low-Memory Fork: Phased Implementation Plan

## 🎯 **Objective**
Create a fork that stores data in partitioned tables with materialized views, ultimately reducing memory from 276MB → 1-3MB through phased, reviewable changes.

## 📊 **Memory Reduction Stages**

### **Current State**
- Default: 256MB + 20MB = **276MB total**

### **Phase 1: Configuration Only**
- `pgsm_max`: 256MB → 10MB (minimum allowed)
- `pgsm_max_buckets`: 10 → 2
- `pgsm_query_shared_buffer`: 20MB → 1MB
- **Result**: 11MB (96% reduction)

### **Phase 3: Clear After Export**
- Keep only current bucket in memory
- Clear immediately after export to table
- **Target**: 1-3MB (99% reduction)

## 🏗️ **Phased Implementation Plan**

---

# **PHASE 1: Table Storage (2 hours)**
*Git diff: ~150 lines in new file + 2 line hook*

## **Objective**
Export statistics to partitioned table on bucket rotation without changing memory usage.

## **Changes**

### **1.1: New File** (`pgsm_table_export.c`)

```c
/*
 * pgsm_table_export.c - Export pg_stat_monitor data to partitioned tables
 * Phase 1: Basic table export functionality
 */
#include "postgres.h"
#include "pg_stat_monitor.h"
#include "executor/spi.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"

/* GUC variable */
bool pgsm_enable_table_export = true;

/* External references */
extern HTAB *pgsm_hash;

/*
 * Export bucket data to partitioned table
 * Called from get_next_wbucket() before bucket cleanup
 */
void
pgsm_export_bucket_to_table(uint64 bucket_id)
{
    HASH_SEQ_STATUS hash_seq;
    pgsmEntry *entry;
    StringInfoData sql;
    int ret, exported = 0;
    bool first = true;

    /* Quick exit if disabled */
    if (!pgsm_enable_table_export)
        return;

    /* Check table exists (will be created by SQL migration) */
    SPI_connect();
    ret = SPI_execute("SELECT 1 FROM pg_tables WHERE tablename = 'pg_stat_monitor_data'",
                      true, 1);
    if (ret != SPI_OK_SELECT || SPI_processed == 0) {
        SPI_finish();
        return;  /* Table doesn't exist yet */
    }
    SPI_finish();

    /* Build batch INSERT */
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "INSERT INTO pg_stat_monitor_data "
        "(bucket_id, queryid, dbid, userid, calls, rows, "
        "total_time, mean_time, min_time, max_time, "
        "shared_blks_hit, shared_blks_read) VALUES ");

    /* Export all entries from this bucket */
    hash_seq_init(&hash_seq, pgsm_hash);
    while ((entry = hash_seq_search(&hash_seq)) != NULL)
    {
        if (entry->key.bucket_id != bucket_id)
            continue;

        if (!first)
            appendStringInfoChar(&sql, ',');
        first = false;

        /* Add entry data */
        appendStringInfo(&sql,
            "(%lu, %lu, %u, %u, %ld, %ld, "
            "%.3f, %.3f, %.3f, %.3f, %ld, %ld)",
            bucket_id,
            entry->pgsm_query_id,
            entry->key.dbid,
            entry->key.userid,
            entry->counters.calls.calls,
            entry->counters.calls.rows,
            entry->counters.time.total_time,
            entry->counters.time.mean_time,
            entry->counters.time.min_time,
            entry->counters.time.max_time,
            entry->counters.blocks.shared_blks_hit,
            entry->counters.blocks.shared_blks_read);

        exported++;
    }

    /* Execute if we have data */
    if (exported > 0)
    {
        SPI_connect();
        ret = SPI_execute(sql.data, false, 0);
        SPI_finish();

        elog(DEBUG1, "pg_stat_monitor: exported %d entries from bucket %lu",
             exported, bucket_id);
    }

    pfree(sql.data);
}
```

### **1.2: Hook Addition** (`pg_stat_monitor.c`)

```diff
+ /* External function from pgsm_table_export.c */
+ extern void pgsm_export_bucket_to_table(uint64 bucket_id);

static uint64
get_next_wbucket(pgsmSharedState *pgsm)
{
    // ... line ~2570 ...
    if (update_bucket)
    {
        new_bucket_id = (tv.tv_sec / pgsm_bucket_time) % pgsm_max_buckets;
        prev_bucket_id = pg_atomic_exchange_u64(&pgsm->current_wbucket, new_bucket_id);

        pgsm_lock_aquire(pgsm, LW_EXCLUSIVE);

+       /* Export bucket data before deallocation */
+       pgsm_export_bucket_to_table(new_bucket_id);

        hash_entry_dealloc(new_bucket_id, prev_bucket_id, NULL);
        pgsm_lock_release(pgsm);
    }
```

### **1.3: SQL Migration** (`pg_stat_monitor--2.0--2.1.sql`)

```sql
-- Phase 1: Create partitioned table for data export
CREATE TABLE IF NOT EXISTS pg_stat_monitor_data (
    bucket_id bigint,
    queryid bigint,
    dbid oid,
    userid oid,
    calls bigint,
    rows bigint,
    total_time double precision,
    mean_time double precision,
    min_time double precision,
    max_time double precision,
    shared_blks_hit bigint,
    shared_blks_read bigint,
    exported_at timestamptz DEFAULT now()
) PARTITION BY RANGE (exported_at);

-- Create initial partition for today
CREATE TABLE pg_stat_monitor_data_default
PARTITION OF pg_stat_monitor_data DEFAULT;

-- Create indexes
CREATE INDEX ON pg_stat_monitor_data (queryid);
CREATE INDEX ON pg_stat_monitor_data (exported_at);

-- Reduce memory usage via configuration
ALTER SYSTEM SET pg_stat_monitor.pgsm_max = '10MB';
ALTER SYSTEM SET pg_stat_monitor.pgsm_max_buckets = 2;
ALTER SYSTEM SET pg_stat_monitor.pgsm_query_shared_buffer = '1MB';
```

### **1.4: Makefile Update**

```diff
- OBJS = hash_query.o guc.o pg_stat_monitor.o $(WIN32RES)
+ OBJS = hash_query.o guc.o pg_stat_monitor.o pgsm_table_export.o $(WIN32RES)
```

### **1.5: GUC Addition** (`guc.c`)

```diff
+ /* Declared in pgsm_table_export.c */
+ extern bool pgsm_enable_table_export;

void
init_guc(void)
{
    // ... existing GUCs ...

+   DefineCustomBoolVariable("pg_stat_monitor.pgsm_enable_table_export",
+                           "Enable export to partitioned tables",
+                           NULL,
+                           &pgsm_enable_table_export,
+                           true,
+                           PGC_SIGHUP,
+                           0,
+                           NULL, NULL, NULL);
}

## **Phase 1 Testing**

```sql
-- Verify export is working
SELECT count(*) FROM pg_stat_monitor_data;

-- Check data contents
SELECT queryid, calls, total_time FROM pg_stat_monitor_data LIMIT 10;
```

---

# **PHASE 2: Materialized View with Bucket-Synced Refresh (1 hour)**
*Git diff: ~30 lines added to existing file*

## **Objective**
Replace existing view with materialized view that refreshes after each bucket export (synchronized with `pgsm_bucket_time`).

## **Changes**

### **2.1: Add Refresh Function** (`pgsm_table_export.c`)

```c
/*
 * Refresh materialized view after bucket export
 * This keeps the view in sync with the data export schedule
 */
void
pgsm_refresh_materialized_view(void)
{
    int ret;

    /* Skip if table export disabled */
    if (!pgsm_enable_table_export)
        return;

    /* Check if materialized view exists */
    SPI_connect();
    ret = SPI_execute("SELECT 1 FROM pg_matviews WHERE matviewname = 'pg_stat_monitor'",
                     true, 1);
    if (ret != SPI_OK_SELECT || SPI_processed == 0) {
        SPI_finish();
        return;  /* Materialized view doesn't exist yet */
    }

    /* Refresh the view (CONCURRENTLY to avoid blocking) */
    ret = SPI_execute("REFRESH MATERIALIZED VIEW CONCURRENTLY pg_stat_monitor",
                     false, 0);
    if (ret == SPI_OK_UTILITY)
    {
        elog(DEBUG1, "pg_stat_monitor: refreshed materialized view");
    }
    SPI_finish();
}
```

### **2.2: Hook After Export** (`pg_stat_monitor.c`)

```diff
+ extern void pgsm_refresh_materialized_view(void);

static uint64
get_next_wbucket(pgsmSharedState *pgsm)
{
    if (update_bucket)
    {
        new_bucket_id = (tv.tv_sec / pgsm_bucket_time) % pgsm_max_buckets;
        prev_bucket_id = pg_atomic_exchange_u64(&pgsm->current_wbucket, new_bucket_id);

        pgsm_lock_aquire(pgsm, LW_EXCLUSIVE);

        /* Export bucket data before deallocation */
        pgsm_export_bucket_to_table(new_bucket_id);

+       /* Refresh materialized view after export (same timing as bucket) */
+       pgsm_refresh_materialized_view();

        hash_entry_dealloc(new_bucket_id, prev_bucket_id, NULL);
        pgsm_lock_release(pgsm);
    }
}
```

### **2.3: SQL Migration** (`pg_stat_monitor--2.1--2.2.sql`)

```sql
-- Phase 2: Replace view with materialized view

-- Save existing view definition
CREATE OR REPLACE VIEW pg_stat_monitor_old AS
SELECT * FROM pg_stat_monitor;

-- Drop existing view
DROP VIEW IF EXISTS pg_stat_monitor;

-- Create materialized view from table data
CREATE MATERIALIZED VIEW pg_stat_monitor AS
SELECT
    bucket_id,
    queryid,
    dbid,
    userid,
    calls,
    rows,
    total_time,
    mean_time,
    min_time,
    max_time,
    shared_blks_hit,
    shared_blks_read
FROM pg_stat_monitor_data
WHERE exported_at > now() - interval '24 hours';

-- Create unique index for CONCURRENT refresh
CREATE UNIQUE INDEX ON pg_stat_monitor (bucket_id, queryid, dbid, userid);

-- Initial population
REFRESH MATERIALIZED VIEW pg_stat_monitor;
```

## **Phase 2 Testing**

```sql
-- Query the materialized view
SELECT * FROM pg_stat_monitor LIMIT 10;

-- Verify refresh timing matches bucket rotation
-- With default pgsm_bucket_time=60, view should refresh every 60 seconds
-- Check PostgreSQL logs for: "pg_stat_monitor: refreshed materialized view"

-- Test with different bucket timing
ALTER SYSTEM SET pg_stat_monitor.pgsm_bucket_time = 30;  -- 30-second buckets
SELECT pg_reload_conf();
-- Now view should refresh every 30 seconds
```

---

# **PHASE 3: Memory Reduction to 1-3MB (2 hours)**
*Git diff: ~100 lines, mostly in isolated functions*

## **Objective**
Clear buckets immediately after export to achieve 1-3MB memory usage.

## **Changes**

### **3.1: Immediate Clear After Export** (`pgsm_table_export.c`)

```c
/*
 * Clear all entries from exported bucket
 * This allows us to keep only current data in memory
 */
void
pgsm_clear_bucket_after_export(uint64 bucket_id)
{
    HASH_SEQ_STATUS hash_seq;
    pgsmEntry *entry;
    int cleared = 0;

    /* Iterate and remove entries from exported bucket */
    hash_seq_init(&hash_seq, pgsm_hash);
    while ((entry = hash_seq_search(&hash_seq)) != NULL)
    {
        if (entry->key.bucket_id == bucket_id)
        {
            /* Remove from hash table */
            hash_search(pgsm_hash, &entry->key, HASH_REMOVE, NULL);
            cleared++;
        }
    }

    elog(DEBUG1, "pg_stat_monitor: cleared %d entries from bucket %lu",
         cleared, bucket_id);
}
```

### **3.2: Modify Export Flow** (`pg_stat_monitor.c`)

```diff
static uint64
get_next_wbucket(pgsmSharedState *pgsm)
{
    if (update_bucket)
    {
        new_bucket_id = (tv.tv_sec / pgsm_bucket_time) % pgsm_max_buckets;
        prev_bucket_id = pg_atomic_exchange_u64(&pgsm->current_wbucket, new_bucket_id);

        pgsm_lock_aquire(pgsm, LW_EXCLUSIVE);

        /* Export bucket data before deallocation */
        pgsm_export_bucket_to_table(new_bucket_id);

+       /* Clear exported bucket immediately to free memory */
+       extern void pgsm_clear_bucket_after_export(uint64);
+       pgsm_clear_bucket_after_export(new_bucket_id);

-       hash_entry_dealloc(new_bucket_id, prev_bucket_id, NULL);
+       /* Skip normal dealloc since we already cleared */

        pgsm_lock_release(pgsm);
    }
}
```

### **3.3: Single Bucket Mode** (`guc.c`)

```diff
void
init_guc(void)
{
+   /* Override to single bucket for minimal memory */
+   if (pgsm_enable_table_export)
+       pgsm_max_buckets = 1;  /* Only current bucket needed */
```

### **3.4: Further Memory Reduction**

```sql
-- Phase 3: Aggressive memory reduction
ALTER SYSTEM SET pg_stat_monitor.pgsm_max = '1MB';  -- Minimum possible
ALTER SYSTEM SET pg_stat_monitor.pgsm_max_buckets = 1;  -- Single bucket
ALTER SYSTEM SET pg_stat_monitor.pgsm_query_shared_buffer = '100kB';  -- Tiny buffer
```

## **Phase 3 Testing**

```sql
-- Check memory usage
SELECT name, size FROM pg_shmem_allocations
WHERE name LIKE '%pg_stat_monitor%';

-- Should show ~1-3MB instead of 276MB
```

---

## **Summary of Changes**

| Phase | Files Changed | Lines Added | Memory Usage | Feature |
|-------|--------------|-------------|--------------|---------|
| **Phase 1** | 4 files | ~150 lines | 11MB | Table export |
| **Phase 2** | 2 files | ~30 lines | 11MB | Mat view + bucket-synced refresh |
| **Phase 3** | 3 files | ~100 lines | **1-3MB** | Clear after export |

**Total Git Diff: ~300 lines across 5 files**

## **Key Benefits**

1. **Phased approach** - Each phase can be reviewed/tested independently
2. **Minimal core changes** - Hooks into existing bucket rotation
3. **No cron needed** - Uses existing function calls for timing
4. **Easy rollback** - Can disable with single GUC
5. **Rebase friendly** - Changes isolated in new file + minimal hooks