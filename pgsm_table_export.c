/*
 * pgsm_table_export.c - Export pg_stat_monitor data to partitioned tables
 * Low-memory implementation with query text limits and top queries filtering
 */
#include "postgres.h"
#include "pg_stat_monitor.h"
#include "executor/spi.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"
#include "catalog/pg_authid.h"
#include "lib/dshash.h"
#include "utils/dsa.h"

/* Helper macro for repeated truncate and escape pattern */
#define APPEND_ESCAPED_STRING(sql, str, max_len) \
    do { \
        if ((str) && strlen(str) > 0) { \
            char *escaped = truncate_and_escape_string((str), (max_len)); \
            appendStringInfo(&(sql), "'%s', ", escaped); \
            pfree(escaped); \
        } else { \
            appendStringInfo(&(sql), "NULL, "); \
        } \
    } while(0)

/* Function declarations */
bool pgsm_export_bucket_to_table(uint64 bucket_id);

/* Configuration */
#define MAX_QUERY_LENGTH 1536    /* 1.5KB limit for query text */
#define MAX_QUERIES_PER_BUCKET 300  /* Top 300 queries per bucket */

/* External references */
extern pgsmSharedState *pgsm_get_ss(void);
extern dsa_area *get_dsa_area_for_query_text(void);

/* Structure for sorting entries by total_time */
typedef struct
{
    pgsmEntry *entry;
    double total_time;
} EntryWithTime;


/*
 * Helper function to truncate and escape strings for SQL
 */
static char *
truncate_and_escape_string(const char *str, int max_len)
{
    int len;
    bool truncated;
    char *result;
    int src_len;
    int j = 0;

    if (!str || *str == '\0')
        return pstrdup("");

    len = strlen(str);
    truncated = (len > max_len);

    /* Simple approach: allocate generous buffer */
    src_len = truncated ? max_len : len;
    result = palloc(src_len * 2 + 10);

    /* Copy and escape quotes */
    for (int i = 0; i < src_len; i++)
    {
        if (str[i] == '\'')
        {
            result[j++] = '\'';
            result[j++] = '\'';
        }
        else
        {
            result[j++] = str[i];
        }
    }

    /* Add truncation marker if needed */
    if (truncated)
    {
        result[j++] = '.';
        result[j++] = '.';
        result[j++] = '.';
    }

    result[j] = '\0';
    return result;
}

/*
 * Helper to convert response calls array to PostgreSQL array format
 */
static char *
resp_calls_to_array(int *resp_calls, int count)
{
    StringInfoData str;
    char *result;


    initStringInfo(&str);

    appendStringInfo(&str, "ARRAY[");
    for (int i = 0; i < count; i++)
    {
        if (i > 0)
            appendStringInfoChar(&str, ',');
        appendStringInfo(&str, "%d", resp_calls[i]);
    }
    appendStringInfo(&str, "]");

    /* Create a copy in the calling context and free the StringInfo */
    result = pstrdup(str.data);

    pfree(str.data);

    return result;
}

/*
 * Comparison function for sorting entries by total_time (descending)
 */
static int
compare_entries_by_time(const void *a, const void *b)
{
    EntryWithTime *ea = (EntryWithTime *)a;
    EntryWithTime *eb = (EntryWithTime *)b;

    if (ea->total_time > eb->total_time)
        return -1;
    else if (ea->total_time < eb->total_time)
        return 1;
    else
        return 0;
}


/*
 * Helper function to collect and sort entries from a bucket
 */
static EntryWithTime *
collect_and_sort_entries(uint64 bucket_id, int *entry_count)
{
    PGSM_HASH_SEQ_STATUS hstat;
    pgsmEntry *entry;
    EntryWithTime *entries_array = NULL;
    int array_size = 1000;  /* Initial allocation */

    *entry_count = 0;

    /* Allocate array for sorting entries */
    entries_array = palloc(array_size * sizeof(EntryWithTime));

    /* First pass: collect all entries from this bucket */
    pgsm_hash_seq_init(&hstat, get_pgsmHash(), false);
    while ((entry = pgsm_hash_seq_next(&hstat)) != NULL)
    {
        if (entry->key.bucket_id != bucket_id)
            continue;

        /* Expand array if needed */
        if (*entry_count >= array_size)
        {
            array_size *= 2;
            entries_array = repalloc(entries_array, array_size * sizeof(EntryWithTime));
        }

        entries_array[*entry_count].entry = entry;
        entries_array[*entry_count].total_time = entry->counters.time.total_time;
        (*entry_count)++;
    }
    pgsm_hash_seq_term(&hstat);

    elog(LOG, "pg_stat_monitor: Found %d entries for bucket %lu", *entry_count, (unsigned long)bucket_id);

    /* Sort entries by total_time descending */
    qsort(entries_array, *entry_count, sizeof(EntryWithTime), compare_entries_by_time);

    return entries_array;
}

/*
 * Helper function to build INSERT SQL statement
 */
/*
 * Build the INSERT statement header with all column names
 */
static void
build_insert_header(StringInfo sql)
{
    appendStringInfo(sql,
        "INSERT INTO pg_stat_monitor "
        "(bucket, bucket_start_time, userid, username, dbid, datname, "
        "client_ip, pgsm_query_id, queryid, toplevel, top_queryid, "
        "query, comments, planid, query_plan, top_query, application_name, relations, "
        "cmd_type, cmd_type_text, elevel, sqlcode, message, "
        "calls, total_exec_time, min_exec_time, max_exec_time, mean_exec_time, stddev_exec_time, rows, "
        "plans, total_plan_time, min_plan_time, max_plan_time, mean_plan_time, stddev_plan_time, "
        "shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, "
        "local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written, "
        "temp_blks_read, temp_blks_written, "
        "shared_blk_read_time, shared_blk_write_time, local_blk_read_time, local_blk_write_time, "
        "temp_blk_read_time, temp_blk_write_time, "
        "cpu_user_time, cpu_sys_time, "
        "wal_records, wal_fpi, wal_bytes, "
        "jit_functions, jit_generation_time, jit_inlining_count, jit_inlining_time, "
        "jit_optimization_count, jit_optimization_time, jit_emission_count, jit_emission_time, "
        "jit_deform_count, jit_deform_time, "
        "resp_calls, stats_since, minmax_stats_since, bucket_done, exported_at"
        ") VALUES ");
}

static char *
build_insert_statement(EntryWithTime *entries_array, int queries_to_export,
                      uint64 bucket_id, pgsmSharedState *pgsm, dsa_area *query_dsa_area)
{
    StringInfoData sql;
    bool first = true;

    /* Build batch INSERT for top queries */
    initStringInfo(&sql);
    build_insert_header(&sql);

    /* Export top N entries using original incremental approach */
    for (int i = 0; i < queries_to_export; i++)
    {
        char *query_txt = NULL;
        char *parent_query_txt = NULL;
        char *query_plan_txt = NULL;
        char *relations_str = NULL;
        double exec_stddev = 0.0;
        double plan_stddev = 0.0;
        double plan_mean __attribute__((unused)) = 0.0;
        char *resp_calls_str;
        pgsmEntry *entry;

        entry = entries_array[i].entry;

        if (!first)
            appendStringInfoChar(&sql, ',');
        first = false;

        /* Get query text - truncated to MAX_QUERY_LENGTH */
        if (DsaPointerIsValid(entry->query_text.query_pos))
        {
            char *query_ptr = dsa_get_address(query_dsa_area, entry->query_text.query_pos);
            query_txt = truncate_and_escape_string(query_ptr, MAX_QUERY_LENGTH);
        }
        else
        {
            query_txt = pstrdup("Query string not available");
        }

        /* Get parent query text if exists - also truncated */
        if (entry->key.parentid != UINT64CONST(0) &&
            DsaPointerIsValid(entry->counters.info.parent_query))
        {
            char *query_ptr = dsa_get_address(query_dsa_area, entry->counters.info.parent_query);
            parent_query_txt = truncate_and_escape_string(query_ptr, MAX_QUERY_LENGTH);
        }

        /* Get relations as comma-separated string */
        if (entry->counters.info.num_relations > 0)
        {
            StringInfoData rel_str;
            initStringInfo(&rel_str);
            for (int j = 0; j < entry->counters.info.num_relations; j++)
            {
                if (j > 0)
                    appendStringInfoChar(&rel_str, ',');
                appendStringInfo(&rel_str, "%s", entry->counters.info.relations[j]);
            }
            /* Create a copy in the calling context and free the StringInfo */
            relations_str = pstrdup(rel_str.data);
            pfree(rel_str.data);
        }

        /* Calculate stddev for exec and plan times */
        if (entry->counters.calls.calls > 1)
            exec_stddev = sqrt(entry->counters.time.sum_var_time / entry->counters.calls.calls);
        if (entry->counters.plancalls.calls > 1)
        {
            plan_stddev = sqrt(entry->counters.plantime.sum_var_time / entry->counters.plancalls.calls);
            plan_mean = entry->counters.plantime.mean_time;
        }

        /* Convert response calls array to PostgreSQL array */
        resp_calls_str = resp_calls_to_array(entry->counters.resp_calls, MAX_RESPONSE_BUCKET);

        /* Get query plan if exists - also truncated */
        if (entry->key.planid && entry->counters.planinfo.plan_text[0])
        {
            query_plan_txt = truncate_and_escape_string(entry->counters.planinfo.plan_text, MAX_QUERY_LENGTH);
        }

        /* Build the VALUES clause for this entry */
        appendStringInfo(&sql,
            "("
            "%ld, ",  /* bucket_id */
            (int64)bucket_id);

        /* bucket_start_time */
        if (pgsm->bucket_start_time[bucket_id] != 0)
            appendStringInfo(&sql, "to_timestamp(%f)::timestamptz, ",
                           (double)(pgsm->bucket_start_time[bucket_id] / 1000000.0));
        else
            appendStringInfo(&sql, "NULL, ");

        {
            char *username_escaped = truncate_and_escape_string(entry->username, NAMEDATALEN);
            char *datname_escaped = truncate_and_escape_string(entry->datname, NAMEDATALEN);

            appendStringInfo(&sql, "%u, '%s', %u, '%s', ",
                entry->key.userid, username_escaped, entry->key.dbid, datname_escaped);

            pfree(username_escaped);
            pfree(datname_escaped);
        }

        /* client_ip */
        if (entry->key.ip != 0)
            appendStringInfo(&sql, "'0.0.0.0'::inet + %ld, ", (int64)entry->key.ip);
        else
            appendStringInfo(&sql, "NULL, ");

        /* pgsm_query_id, queryid */
        appendStringInfo(&sql, "%ld, %ld, ",
            (int64)entry->pgsm_query_id,
            (int64)entry->key.queryid);

        /* toplevel */
        appendStringInfo(&sql, "%s, ", entry->key.toplevel ? "true" : "false");

        /* top_queryid */
        if (entry->key.parentid != UINT64CONST(0))
            appendStringInfo(&sql, "%ld, ", (int64)entry->key.parentid);
        else
            appendStringInfo(&sql, "NULL, ");

        /* query */
        appendStringInfo(&sql, "'%s', ", query_txt);

        /* comments */
        APPEND_ESCAPED_STRING(sql, entry->counters.info.comments, 256);

        /* planid */
        if (entry->key.planid)
            appendStringInfo(&sql, "%ld, ", (int64)entry->key.planid);
        else
            appendStringInfo(&sql, "NULL, ");

        /* query_plan */
        if (query_plan_txt)
            appendStringInfo(&sql, "'%s', ", query_plan_txt);
        else
            appendStringInfo(&sql, "NULL, ");

        /* top_query */
        if (parent_query_txt)
            appendStringInfo(&sql, "'%s', ", parent_query_txt);
        else
            appendStringInfo(&sql, "NULL, ");

        /* application_name */
        APPEND_ESCAPED_STRING(sql, entry->counters.info.application_name, NAMEDATALEN);

        /* relations - convert to PostgreSQL array format */
        if (relations_str && strlen(relations_str) > 0)
        {
            char *relations_copy;
            char *token;
            bool first_rel = true;

            appendStringInfo(&sql, "ARRAY[");
            relations_copy = pstrdup(relations_str);
            token = strtok(relations_copy, ",");
            while (token != NULL)
            {
                if (!first_rel)
                    appendStringInfoChar(&sql, ',');
                appendStringInfo(&sql, "'%s'", token);
                first_rel = false;
                token = strtok(NULL, ",");
            }
            appendStringInfo(&sql, "], ");
            pfree(relations_copy);
        }
        else
            appendStringInfo(&sql, "NULL, ");

        /* cmd_type */
        if (entry->counters.info.cmd_type != CMD_NOTHING)
            appendStringInfo(&sql, "%d, ", entry->counters.info.cmd_type);
        else
            appendStringInfo(&sql, "NULL, ");

        /* cmd_type_text - convert to text */
        switch (entry->counters.info.cmd_type)
        {
            case CMD_SELECT:
                appendStringInfo(&sql, "'SELECT', ");
                break;
            case CMD_UPDATE:
                appendStringInfo(&sql, "'UPDATE', ");
                break;
            case CMD_INSERT:
                appendStringInfo(&sql, "'INSERT', ");
                break;
            case CMD_DELETE:
                appendStringInfo(&sql, "'DELETE', ");
                break;
            case CMD_UTILITY:
                appendStringInfo(&sql, "'UTILITY', ");
                break;
            case CMD_NOTHING:
            default:
                appendStringInfo(&sql, "NULL, ");
                break;
        }

        /* elevel, sqlcode, message */
        appendStringInfo(&sql, "%ld, ", (long)entry->counters.error.elevel);

        APPEND_ESCAPED_STRING(sql, entry->counters.error.sqlcode, 5);
        APPEND_ESCAPED_STRING(sql, entry->counters.error.message, 256);

        /* Execution stats */
        appendStringInfo(&sql,
            "%ld, %.3f, %.3f, %.3f, %.3f, %.3f, %ld, ",
            entry->counters.calls.calls,
            entry->counters.time.total_time,
            entry->counters.time.min_time,
            entry->counters.time.max_time,
            entry->counters.time.mean_time,
            exec_stddev,
            entry->counters.calls.rows);

        /* Planning stats */
        appendStringInfo(&sql,
            "%ld, %.3f, %.3f, %.3f, %.3f, %.3f, ",
            entry->counters.plancalls.calls,
            entry->counters.plantime.total_time,
            entry->counters.plantime.min_time,
            entry->counters.plantime.max_time,
            entry->counters.plantime.mean_time,
            plan_stddev);

        /* Block stats */
        appendStringInfo(&sql,
            "%ld, %ld, %ld, %ld, %ld, %ld, %ld, %ld, %ld, %ld, "
            "%.3f, %.3f, %.3f, %.3f, %.3f, %.3f, ",
            entry->counters.blocks.shared_blks_hit,
            entry->counters.blocks.shared_blks_read,
            entry->counters.blocks.shared_blks_dirtied,
            entry->counters.blocks.shared_blks_written,
            entry->counters.blocks.local_blks_hit,
            entry->counters.blocks.local_blks_read,
            entry->counters.blocks.local_blks_dirtied,
            entry->counters.blocks.local_blks_written,
            entry->counters.blocks.temp_blks_read,
            entry->counters.blocks.temp_blks_written,
            entry->counters.blocks.shared_blk_read_time,
            entry->counters.blocks.shared_blk_write_time,
            entry->counters.blocks.local_blk_read_time,
            entry->counters.blocks.local_blk_write_time,
            entry->counters.blocks.temp_blk_read_time,
            entry->counters.blocks.temp_blk_write_time);

        /* System stats */
        appendStringInfo(&sql,
            "%.3f, %.3f, ",
            entry->counters.sysinfo.utime,
            entry->counters.sysinfo.stime);

        /* WAL stats */
        appendStringInfo(&sql,
            "%ld, %ld, %ld, ",
            entry->counters.walusage.wal_records,
            entry->counters.walusage.wal_fpi,
            (int64)entry->counters.walusage.wal_bytes);

        /* JIT stats */
        appendStringInfo(&sql,
            "%ld, %.3f, %ld, %.3f, %ld, %.3f, %ld, %.3f, %ld, %.3f, ",
            entry->counters.jitinfo.jit_functions,
            entry->counters.jitinfo.jit_generation_time,
            entry->counters.jitinfo.jit_inlining_count,
            entry->counters.jitinfo.jit_inlining_time,
            entry->counters.jitinfo.jit_optimization_count,
            entry->counters.jitinfo.jit_optimization_time,
            entry->counters.jitinfo.jit_emission_count,
            entry->counters.jitinfo.jit_emission_time,
            entry->counters.jitinfo.jit_deform_count,
            entry->counters.jitinfo.jit_deform_time);

        /* resp_calls */
        appendStringInfo(&sql, "%s, ", resp_calls_str);

        /* stats_since, minmax_stats_since */
        if (entry->stats_since != 0)
            appendStringInfo(&sql, "to_timestamp(%f)::timestamptz, ",
                           (double)(entry->stats_since / 1000000.0));
        else
            appendStringInfo(&sql, "NULL, ");

        if (entry->minmax_stats_since != 0)
            appendStringInfo(&sql, "to_timestamp(%f)::timestamptz, ",
                           (double)(entry->minmax_stats_since / 1000000.0));
        else
            appendStringInfo(&sql, "NULL, ");

        /* bucket_done - mark as false since bucket is still active */
        appendStringInfo(&sql, "false, ");

        /* exported_at - use current timestamp */
        appendStringInfo(&sql, "now())");

        /* Clean up */
        if (query_txt)
            pfree(query_txt);
        if (parent_query_txt)
            pfree(parent_query_txt);
        if (query_plan_txt)
            pfree(query_plan_txt);
        if (relations_str)
            pfree(relations_str);
        if (resp_calls_str)
            pfree(resp_calls_str);
    }

    {
        char *result = pstrdup(sql.data);
        /* StringInfo manages its own memory - don't call pfree on sql.data */
        return result;
    }
}

/*
 * Helper function to execute SQL statement
 */
static bool
execute_export_sql(const char *sql, uint64 bucket_id, int exported)
{
    int spi_result;
    int ret;
    bool export_successful = false;
    bool spi_connected = false;

    elog(LOG, "pg_stat_monitor: About to export %d queries for bucket %lu", exported, (unsigned long)bucket_id);

    /* Attempt SPI execution with proper error handling */
    PG_TRY();
    {
        /* Try to connect to SPI manager */
        spi_result = SPI_connect();
        if (spi_result != SPI_OK_CONNECT)
        {
            elog(DEBUG1, "pg_stat_monitor: Deferring export of bucket %lu (SPI connect failed: %d)",
                 (unsigned long)bucket_id, spi_result);
            export_successful = false;
        }
        else
        {
            spi_connected = true;

            /* Execute the INSERT statement */
            elog(LOG, "pg_stat_monitor: Executing SQL for bucket %lu", (unsigned long)bucket_id);
            elog(LOG, "pg_stat_monitor: FULL SQL: %s", sql);

            /* Add pre-execution debugging */
            elog(LOG, "pg_stat_monitor: About to call SPI_execute");
            elog(LOG, "pg_stat_monitor: SPI connection status: %d", SPI_result);

            ret = SPI_execute(sql, false, 0);

            elog(LOG, "pg_stat_monitor: SPI_execute returned: %d", ret);
            elog(LOG, "pg_stat_monitor: SPI_OK_INSERT value is: %d", SPI_OK_INSERT);
            elog(LOG, "pg_stat_monitor: SPI_processed: %lu", (unsigned long)SPI_processed);

            /* Check result */
            if (ret == SPI_OK_INSERT)
            {
                elog(LOG, "pg_stat_monitor: Successfully exported %d queries for bucket %lu",
                     exported, (unsigned long)bucket_id);
                export_successful = true;
            }
            else
            {
                elog(WARNING, "pg_stat_monitor: Failed to insert bucket %lu data, SPI result: %d",
                     (unsigned long)bucket_id, ret);
                export_successful = false;
            }

            /* Always call SPI_finish() after successful SPI_connect() */
            SPI_finish();
            spi_connected = false;
        }
    }
    PG_CATCH();
    {
        /* Handle SPI context errors gracefully */
        ErrorData *errdata;

        /* Clean up SPI connection if it was established */
        if (spi_connected)
        {
            SPI_finish();
        }

        errdata = CopyErrorData();
        elog(DEBUG1, "pg_stat_monitor: Export deferred for bucket %lu: %s",
             (unsigned long)bucket_id, errdata->message);
        FreeErrorData(errdata);
        FlushErrorState();
        export_successful = false;
    }
    PG_END_TRY();

    return export_successful;
}

/*
 * Export bucket data to partitioned table
 * Called from ExecutorEnd when a bucket needs export
 * Returns true if export succeeded or no data to export, false if deferred
 */
bool
pgsm_export_bucket_to_table(uint64 bucket_id)
{
    EntryWithTime *entries_array = NULL;
    char *sql = NULL;
    pgsmSharedState *pgsm;
    dsa_area *query_dsa_area;
    int entry_count, queries_to_export;
    bool export_successful = false;

    /* Log when export function is called */
    elog(DEBUG1, "pg_stat_monitor: Export function called for bucket %lu", (unsigned long)bucket_id);

    /* Get shared memory areas */
    pgsm = pgsm_get_ss();
    query_dsa_area = get_dsa_area_for_query_text();

    /* Step 1: Collect and sort entries from this bucket */
    entries_array = collect_and_sort_entries(bucket_id, &entry_count);

    /* Step 2: Limit to top N queries */
    queries_to_export = (entry_count > MAX_QUERIES_PER_BUCKET) ?
                        MAX_QUERIES_PER_BUCKET : entry_count;

    if (queries_to_export == 0)
    {
        elog(DEBUG1, "pg_stat_monitor: No data to export for bucket %lu (found %d entries)",
             (unsigned long)bucket_id, entry_count);
        export_successful = true;  /* No data to export is success */
        goto cleanup;
    }

    /* Step 3: Build INSERT SQL statement */
    sql = build_insert_statement(entries_array, queries_to_export, bucket_id, pgsm, query_dsa_area);

    /* Step 4: Execute SQL statement */
    export_successful = execute_export_sql(sql, bucket_id, queries_to_export);
    elog(LOG, "pg_stat_monitor: execute_export_sql returned %s for bucket %lu",
         export_successful ? "true" : "false", (unsigned long)bucket_id);

cleanup:
    /* Single cleanup point to avoid double-free errors */
    if (sql)
        pfree(sql);
    if (entries_array)
        pfree(entries_array);

    elog(LOG, "pg_stat_monitor: pgsm_export_bucket_to_table returning %s for bucket %lu",
         export_successful ? "true" : "false", (unsigned long)bucket_id);
    return export_successful;
}

/*
 * User-callable export function following PostgreSQL extension best practices
 * This is the safe way to trigger exports - from a proper transaction context
 * Similar to pg_stat_statements_reset() pattern
 */
PG_FUNCTION_INFO_V1(pg_stat_monitor_export);

Datum
pg_stat_monitor_export(PG_FUNCTION_ARGS)
{
    pgsmSharedState *pgsm = pgsm_get_ss();
    uint64 bucket_to_export;
    uint64 current_bucket_id;
    int exported_buckets = 0;

    /* Check if user has appropriate permissions */
    if (!superuser())
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("must be superuser to export pg_stat_monitor data")));

    /* Get current bucket ID */
    current_bucket_id = pg_atomic_read_u64(&pgsm->current_wbucket);

    /* Check for pending exports */
    bucket_to_export = pg_atomic_read_u64(&pgsm->bucket_to_export);

    /* Determine which bucket to export */
    {
        uint64 target_bucket = (bucket_to_export == (uint64)-1) ? current_bucket_id : bucket_to_export;

    /* Export the target bucket */
    if (pgsm_export_bucket_to_table(target_bucket))
    {
        exported_buckets = 1;
        /* Clear export flag if it was a pending export */
        if (bucket_to_export != (uint64)-1)
            pg_atomic_compare_exchange_u64(&pgsm->bucket_to_export, &bucket_to_export, (uint64)-1);
    }
    }

    PG_RETURN_INT32(exported_buckets);
}