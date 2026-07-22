/*-------------------------------------------------------------------------
 *
 * pg_stat_monitor.c
 *	  Track statement execution times across a whole database cluster.
 *
 * Portions Copyright © 2018-2025, Percona LLC and/or its affiliates
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#include <postgres.h>

#include <arpa/inet.h>
#include <math.h>
#include <sys/resource.h>
#include <sys/time.h>

#include <access/hash.h>
#include <access/parallel.h>
#include <access/xact.h>
#include <catalog/pg_authid.h>
#include <catalog/pg_class.h>
#include <commands/dbcommands.h>
#include <commands/explain.h>
#include <common/ip.h>
#include <funcapi.h>
#include <jit/jit.h>
#include <libpq/libpq-be.h>
#include <mb/pg_wchar.h>
#include <miscadmin.h>
#include <nodes/pg_list.h>
#include <optimizer/planner.h>
#include <parser/analyze.h>
#include <parser/parsetree.h>
#include <parser/scanner.h>
#include <parser/scansup.h>
#include <storage/ipc.h>
#include <storage/proc.h>
#include <storage/shmem.h>
#include <tcop/utility.h>
#include <utils/acl.h>
#include <utils/builtins.h>
#include <utils/lsyscache.h>
#include <utils/memutils.h>

#if PG_VERSION_NUM >= 180000
#include <commands/explain_state.h>
#include <commands/explain_format.h>
#endif

#include "guc.h"
#include "hash_query.h"

#define BUILD_VERSION "2.4.0"

#if PG_VERSION_NUM >= 180000
PG_MODULE_MAGIC_EXT(.name = "pg_stat_monitor",.version = BUILD_VERSION);
#else
PG_MODULE_MAGIC;
#endif

/* Number of output arguments (columns) for various API versions */
#define PG_STAT_MONITOR_COLS_V1_0	52
#define PG_STAT_MONITOR_COLS_V2_0	64
#define PG_STAT_MONITOR_COLS_V2_1	70
#define PG_STAT_MONITOR_COLS_V2_3	73
#define PG_STAT_MONITOR_COLS		PG_STAT_MONITOR_COLS_V2_3	/* maximum of above */

#define pgsm_enabled(level) \
    (!IsParallelWorker() && \
    (pgsm_track == PGSM_TRACK_ALL || \
    (pgsm_track == PGSM_TRACK_TOP && (level) == 0)))

#define PGSM_INVALID_IP 0xFFFFFFFF

 /*
  * Extension version number, for supporting older extension versions' objects
  */
typedef enum pgsmVersion
{
	PGSM_V1_0 = 0,
	PGSM_V2_0,
	PGSM_V2_1,
	PGSM_V2_3,
} pgsmVersion;

/*---- Initialization Function Declarations ----*/
void		_PG_init(void);

static MemoryContext PgsmMemoryContext;

/* Current nesting depth of planner/ExecutorRun/ProcessUtility calls */
static int	nesting_level = 0;
static int	max_nesting_level;

#if PG_VERSION_NUM < 170000
/* Before planner nesting level was counted separately */
static int	plan_nested_level = 0;
#endif

/* Histogram bucket variables */
static double hist_bucket_min;
static double hist_bucket_max;
static struct
{
	double		start;
	double		end;
}			hist_bucket_timings[MAX_RESPONSE_BUCKET + 2];
static int	hist_bucket_count_user;
static int	hist_bucket_count_total;

/* The array to store outer layer query id */
static int64 *nested_queryids;
static char **nested_query_txts;
static List *lentries = NIL;

static char relations[REL_LST][REL_LEN];

static int	num_relations;		/* Number of relation in the query */
static bool system_init = false;
static struct rusage rusage_start;

/* Cached per-backend information */
static char datname[NAMEDATALEN];
static uint32 client_ip = PGSM_INVALID_IP;

/* Query buffer, store queries' text. */
static char *pgsm_explain(QueryDesc *queryDesc);

static void pgsm_shmem_startup(void);
static void extract_query_comments(const char *query, char *comments, size_t max_len);
static void set_histogram_bucket_timings(void);
static void histogram_bucket_timings(int index, double *b_start, double *b_end);
static int	get_histogram_bucket(double q_time);

static bool IsSystemInitialized(void);
static double time_diff(struct timeval end, struct timeval start);
static void request_additional_shared_resources(void);

/* Hooks */
#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif
static planner_hook_type planner_hook_next = NULL;
static post_parse_analyze_hook_type prev_post_parse_analyze_hook = NULL;
static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorRun_hook_type prev_ExecutorRun = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static ProcessUtility_hook_type prev_ProcessUtility = NULL;
static emit_log_hook_type prev_emit_log_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

#if PG_VERSION_NUM >= 150000
static void pgsm_shmem_request(void);
#endif
static void pgsm_emit_log_hook(ErrorData *edata);
static void pgsm_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate);
static void pgsm_ExecutorStart(QueryDesc *queryDesc, int eflags);
#if PG_VERSION_NUM >= 180000
static void pgsm_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count);
#else
static void pgsm_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count, bool execute_once);
#endif
static void pgsm_ExecutorFinish(QueryDesc *queryDesc);
static void pgsm_ExecutorEnd(QueryDesc *queryDesc);
static PlannedStmt *pgsm_planner_hook(Query *parse, const char *query_string,
									  int cursorOptions, ParamListInfo boundParams);
static void pgsm_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
								bool readOnlyTree,
								ProcessUtilityContext context,
								ParamListInfo params, QueryEnvironment *queryEnv,
								DestReceiver *dest,
								QueryCompletion *qc);

PG_FUNCTION_INFO_V1(pg_stat_monitor_version);
PG_FUNCTION_INFO_V1(pg_stat_monitor_reset);
PG_FUNCTION_INFO_V1(pg_stat_monitor_1_0);
PG_FUNCTION_INFO_V1(pg_stat_monitor_2_0);
PG_FUNCTION_INFO_V1(pg_stat_monitor_2_1);
PG_FUNCTION_INFO_V1(pg_stat_monitor_2_3);
PG_FUNCTION_INFO_V1(pg_stat_monitor);
PG_FUNCTION_INFO_V1(get_histogram_timings);
PG_FUNCTION_INFO_V1(pg_stat_monitor_hook_stats);
PG_FUNCTION_INFO_V1(pg_stat_monitor_decode_error_level);
PG_FUNCTION_INFO_V1(pg_stat_monitor_get_cmd_type);

static uint pg_get_client_addr(void);
static void pgsm_set_cached_info(void);
static Datum intarray_get_datum(const int32 *arr, int len);

static int64 pgsm_hash_string(const char *str, int len);


/*
 * Structure to accumulate query statistics in local memory before putting them into bucket.
 */
typedef struct pgsmQueryStats
{
	pgsmHashKey key;			/* key used to find/create the shared
								 * pgsmEntry */
	int64		pgsm_query_id;	/* pgsm generate normalized query hash */
	SubTransactionId subxid;	/* subtransaction the query belongs to */
	char	   *query;			/* query text, palloc'd in local context */
	char		appname[NAMEDATALEN];	/* application name */
	char		username[NAMEDATALEN];	/* user name */
	Counters	counters;		/* the statistics for this query */
} pgsmQueryStats;

/*
 * Structure to store information about the current statement execution.
 * This data may change during the execution of the query and for statistics
 * we need to know this data at the time when the statement execution started.
 */
typedef struct pgsmQueryExecInfo
{
	Oid			userid;
	char		appname[NAMEDATALEN];
	char		username[NAMEDATALEN];
} pgsmQueryExecInfo;

static MemoryContext pgsm_memory_context(void);
static void pgsm_fill_query_exec_info(pgsmQueryExecInfo *info);
static pgsmQueryStats *pgsm_add_query_stats(int64 queryid, int64 planid, int64 pgsm_query_id, const char *query_text, int query_len, CmdType cmd_type);
static void pgsm_fill_query_stats(pgsmQueryStats *stats, const pgsmQueryExecInfo *info, int64 queryid, int64 planid, int64 pgsm_query_id, const char *query_text, CmdType cmd_type);
static void pgsm_delete_query_stats(uint64 queryid);
static pgsmQueryStats *pgsm_get_query_stats(int64 queryid, int64 planid, const char *query_text, CmdType cmd_type);
static int64 get_pgsm_query_id_hash(const char *norm_query, int len);

static void pgsm_cleanup_callback(void *arg);
static void pgsm_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
								  SubTransactionId parentSubid, void *arg);
static void pgsm_store_error(const char *query, const ErrorData *edata);

/*---- Local variables ----*/
static MemoryContextCallback mem_cxt_reset_callback =
{
	.func = pgsm_cleanup_callback,
	.arg = NULL
};

static void pgsm_update_counters(Counters *counters,
								 const PlanInfo *plan_info,
								 const SysInfo *sys_info,
								 double plan_total_time,
								 double exec_total_time,
								 uint64 rows,
								 const BufferUsage *bufusage,
								 const WalUsage *walusage,
								 const struct JitInstrumentation *jitusage,
								 int parallel_workers_to_launch,
								 int parallel_workers_launched);
static void pgsm_merge_counters(Counters *dst, const Counters *src);
static void pgsm_store(const pgsmQueryStats *stats);

static void pg_stat_monitor_internal(FunctionCallInfo fcinfo,
									 pgsmVersion api_version,
									 bool showtext);

static char *generate_normalized_query(JumbleState *jstate, const char *query,
									   int query_loc, int *query_len_p);
static void fill_in_constant_lengths(JumbleState *jstate, const char *query, int query_loc);
static int	comp_location(const void *a, const void *b);

static uint64 get_next_wbucket(pgsmSharedState *pgsm);

/*
 * To prevent deadlocks against our own backend we need to disable error
 * capture while holding the LWLock. The error capture hook is responsible
 * itself for re-enabling data capture when called on ERROR or above since
 * then we may not have been able to call pgsm_lock_release() due to the
 * statement being aborted.
 */
static bool disable_error_capture = false;

static void pgsm_lock_aquire(pgsmSharedState *pgsm, LWLockMode mode);
static void pgsm_lock_release(pgsmSharedState *pgsm);

/*
 * Module load callback
 */
/*  cppcheck-suppress unusedFunction */
void
_PG_init(void)
{
	MemoryContext oldctx;

	elog(DEBUG2, "[pg_stat_monitor] pg_stat_monitor: %s().", __FUNCTION__);

	/*
	 * In order to create our shared memory area, we have to be loaded via
	 * shared_preload_libraries.  If not, fall out without hooking into any of
	 * the main system.  (We don't throw error here because it seems useful to
	 * allow the pg_stat_monitor functions to be created even when the module
	 * isn't active.  The functions must protect themselves against being
	 * called then, however.)
	 */
	if (!process_shared_preload_libraries_in_progress)
		return;

	/* Initialize the GUC variables */
	init_guc();

	set_histogram_bucket_timings();

	/*
	 * Inform the postmaster that we want to enable query_id calculation if
	 * compute_query_id is set to auto.
	 */
	EnableQueryId();

	EmitWarningsOnPlaceholders("pg_stat_monitor");

	/*
	 * Install hooks.
	 */
#if PG_VERSION_NUM >= 150000
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = pgsm_shmem_request;
#else
	request_additional_shared_resources();
#endif
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = pgsm_shmem_startup;
	prev_post_parse_analyze_hook = post_parse_analyze_hook;
	post_parse_analyze_hook = pgsm_post_parse_analyze;
	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = pgsm_ExecutorStart;
	prev_ExecutorRun = ExecutorRun_hook;
	ExecutorRun_hook = pgsm_ExecutorRun;
	prev_ExecutorFinish = ExecutorFinish_hook;
	ExecutorFinish_hook = pgsm_ExecutorFinish;
	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = pgsm_ExecutorEnd;
	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = pgsm_ProcessUtility;
	planner_hook_next = planner_hook;
	planner_hook = pgsm_planner_hook;
	prev_emit_log_hook = emit_log_hook;
	emit_log_hook = pgsm_emit_log_hook;

	RegisterSubXactCallback(pgsm_subxact_callback, NULL);

	/*
	 * Use max_stack_depth as a very high and very rough estimate for maximum
	 * query nesting.
	 */
	max_nesting_level = max_stack_depth;

	oldctx = MemoryContextSwitchTo(TopMemoryContext);

	nested_queryids = palloc_array(int64, max_nesting_level);
	nested_query_txts = palloc0_array(char *, max_nesting_level);

	MemoryContextSwitchTo(oldctx);
}

/*
 * shmem_startup hook: allocate or attach to shared memory,
 * then load any pre-existing statistics from file.
 * Also create and load the query-texts file, which is expected to exist
 * (even if empty) while the module is enabled.
 */
static void
pgsm_shmem_startup(void)
{
	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	pgsm_startup();

	system_init = true;
}

static void
request_additional_shared_resources(void)
{
	/*
	 * Request additional shared resources.  (These are no-ops if we're not in
	 * the postmaster process.)  We'll allocate or attach to the shared
	 * resources in pgsm_shmem_startup().
	 */
	RequestAddinShmemSpace(pgsm_ShmemSize());
	RequestNamedLWLockTranche("pg_stat_monitor", 1);
}

/*
 * Select the version of pg_stat_monitor.
 */
Datum
pg_stat_monitor_version(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(BUILD_VERSION));
}

#if PG_VERSION_NUM >= 150000
/*
 * shmem_request hook: request additional shared resources.  We'll allocate or
 * attach to the shared resources in pgsm_shmem_startup().
 */
static void
pgsm_shmem_request(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();
	request_additional_shared_resources();
}
#endif

static void
pgsm_post_parse_analyze_internal(ParseState *pstate, Query *query, JumbleState *jstate)
{
	const char *query_text;
	int			query_len;
	const char *hash_text;
	int			hash_text_len;
	const char *store_text;
	int			store_text_len;
	char	   *norm_query = NULL;
	int			norm_query_len;
	int			location;

	/* Safety check... */
	if (!IsSystemInitialized())
		return;

	if (!pgsm_enabled(nesting_level))
		return;

	/*
	 * If it's EXECUTE, clear the queryId so that stats will accumulate for
	 * the underlying PREPARE.  But don't do this if we're not tracking
	 * utility statements, to avoid messing up another extension that might be
	 * tracking them.
	 */
	if (query->utilityStmt)
	{
		if (pgsm_track_utility && IsA(query->utilityStmt, ExecuteStmt))
			query->queryId = INT64CONST(0);

		return;
	}

	/*
	 * If we are unlucky enough to get a hash of zero, use 1 instead, to
	 * prevent confusion with the utility-statement case.
	 */
	if (query->queryId == INT64CONST(0))
		query->queryId = INT64CONST(1);

	/*
	 * Let's save the normalized query so that we can save the data without in
	 * hash later on without the need of jstate which wouldn't be available.
	 */
	query_text = pstate->p_sourcetext;
	location = query->stmt_location;
	query_len = query->stmt_len;

	/* We should always have a valid query. */
	query_text = CleanQuerytext(query_text, &location, &query_len);
	Assert(query_text);

	norm_query_len = query_len;

	/* Generate a normalized query */
	if (jstate && jstate->clocations_count > 0 && (pgsm_enable_pgsm_query_id || pgsm_normalized_query))
	{
		norm_query = generate_normalized_query(jstate,
											   query_text,	/* query */
											   location,	/* query location */
											   &norm_query_len);

		Assert(norm_query);
	}

	/*
	 * pgsm_query_id always groups by the normalized form when we have one.
	 * But what gets stored as query text depends on the pgsm_normalized_query
	 * GUC.
	 */
	hash_text = norm_query ? norm_query : query_text;
	hash_text_len = norm_query ? norm_query_len : query_len;
	store_text = pgsm_normalized_query ? hash_text : query_text;
	store_text_len = pgsm_normalized_query ? hash_text_len : query_len;

	/*
	 * At this point, we don't know which bucket this query will land in, so
	 * passing 0. The store function MUST later update it based on the current
	 * bucket value. The correct bucket value will be needed then to search
	 * the hash table, or create the appropriate entry.
	 */
	pgsm_add_query_stats(query->queryId, 0,
						 get_pgsm_query_id_hash(hash_text, hash_text_len),
						 store_text, store_text_len, query->commandType);

	Assert(list_length(lentries) <= max_nesting_level);

	if (norm_query)
		pfree(norm_query);
}

/*
 * Post-parse-analysis hook: mark query with a queryId
 */
static void
pgsm_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate)
{
	if (prev_post_parse_analyze_hook)
		prev_post_parse_analyze_hook(pstate, query, jstate);

	pgsm_post_parse_analyze_internal(pstate, query, jstate);
}

/*
 * ExecutorStart hook: start up tracking if needed
 */
static void
pgsm_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	if (pgsm_enabled(nesting_level))
		getrusage(RUSAGE_SELF, &rusage_start);

	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);

	/*
	 * If query has queryId zero, don't track it.  This prevents double
	 * counting of optimizable statements that are directly contained in
	 * utility statements.
	 */
	if (pgsm_enabled(nesting_level) &&
		queryDesc->plannedstmt->queryId != INT64CONST(0))
	{
		ListCell   *lr;
		Oid			reloids[REL_LST];

		/*
		 * Set up to track total elapsed time in ExecutorRun.  Make sure the
		 * space is allocated in the per-query context so it will go away at
		 * ExecutorEnd.
		 */
		if (queryDesc->totaltime == NULL)
		{
			MemoryContext oldcxt;

			oldcxt = MemoryContextSwitchTo(queryDesc->estate->es_query_cxt);
			queryDesc->totaltime = InstrAlloc(1, INSTRUMENT_ALL, false);
			MemoryContextSwitchTo(oldcxt);
		}

		/*
		 * Save names of relations involved in the qeury.
		 *
		 * TODO: Should this be done in the ExecutorEnd hook instead?
		 */
		num_relations = 0;

		foreach(lr, queryDesc->plannedstmt->rtable)
		{
			RangeTblEntry *rte = lfirst_node(RangeTblEntry, lr);
			bool		found = false;
			char	   *namespace_name;
			char	   *relation_name;

			if (rte->rtekind != RTE_RELATION
#if PG_VERSION_NUM >= 160000
				&& rte->rtekind != RTE_SUBQUERY && rte->relkind != RELKIND_VIEW
#endif
				)
				continue;

			/* Skip duplicates */
			for (int i = 0; i < num_relations; i++)
			{
				if (reloids[i] == rte->relid)
				{
					found = true;
					break;
				}
			}
			if (found)
				continue;

			reloids[num_relations] = rte->relid;

			namespace_name = get_namespace_name(get_rel_namespace(rte->relid));
			relation_name = get_rel_name(rte->relid);

			if (rte->relkind == RELKIND_VIEW)
				snprintf(relations[num_relations], REL_LEN, "%s.%s*", namespace_name, relation_name);
			else
				snprintf(relations[num_relations], REL_LEN, "%s.%s", namespace_name, relation_name);

			num_relations++;

			/* Only save the first REL_LST number of relations */
			if (num_relations == REL_LST)
				break;
		}
	}
}

/*
 * ExecutorRun hook: all we need do is track nesting depth
 */
static void
#if PG_VERSION_NUM >= 180000
pgsm_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count)
#else
pgsm_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count,
				 bool execute_once)
#endif
{
	if (nesting_level >= 0 && nesting_level < max_nesting_level)
	{
		nested_queryids[nesting_level] = queryDesc->plannedstmt->queryId;
		nested_query_txts[nesting_level] = strdup(queryDesc->sourceText);
	}

	nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorRun)
		{
#if PG_VERSION_NUM >= 180000
			prev_ExecutorRun(queryDesc, direction, count);
#else
			prev_ExecutorRun(queryDesc, direction, count, execute_once);
#endif
		}
		else
		{
#if PG_VERSION_NUM >= 180000
			standard_ExecutorRun(queryDesc, direction, count);
#else
			standard_ExecutorRun(queryDesc, direction, count, execute_once);
#endif
		}
	}
	PG_FINALLY();
	{
		nesting_level--;
		if (nesting_level >= 0 && nesting_level < max_nesting_level)
		{
			nested_queryids[nesting_level] = INT64CONST(0);
			if (nested_query_txts[nesting_level])
				free(nested_query_txts[nesting_level]);
			nested_query_txts[nesting_level] = NULL;
		}
	}
	PG_END_TRY();
}

/*
 * ExecutorFinish hook: all we need do is track nesting depth
 */
static void
pgsm_ExecutorFinish(QueryDesc *queryDesc)
{
	nesting_level++;

	PG_TRY();
	{
		if (prev_ExecutorFinish)
			prev_ExecutorFinish(queryDesc);
		else
			standard_ExecutorFinish(queryDesc);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();
}

static char *
pgsm_explain(QueryDesc *queryDesc)
{
	ExplainState *es = NewExplainState();

	es->buffers = false;
	es->analyze = false;
	es->verbose = false;
	es->costs = false;
	es->format = EXPLAIN_FORMAT_TEXT;

	ExplainBeginOutput(es);
	ExplainPrintPlan(es, queryDesc);
	ExplainEndOutput(es);

	if (es->str->len > 0 && es->str->data[es->str->len - 1] == '\n')
		es->str->data[--es->str->len] = '\0';
	return es->str->data;
}

/*
 * ExecutorEnd hook: store results if needed
 */
static void
pgsm_ExecutorEnd(QueryDesc *queryDesc)
{
	int64		queryId = queryDesc->plannedstmt->queryId;
	PlanInfo	plan_info;
	PlanInfo   *plan_ptr = NULL;

	/* Extract the plan information in case of SELECT statement */
	if (queryDesc->operation == CMD_SELECT && pgsm_enable_query_plan)
	{
		int			plan_len;
		MemoryContext oldctx;

		/*
		 * Run explain in a per query context so that there's no memory leak
		 * when executor ends.
		 */
		oldctx = MemoryContextSwitchTo(queryDesc->estate->es_query_cxt);

		plan_len = strlcpy(plan_info.plan_text, pgsm_explain(queryDesc), PLAN_TEXT_LEN);

		MemoryContextSwitchTo(oldctx);

		plan_info.plan_len = plan_len < PLAN_TEXT_LEN ? plan_len : PLAN_TEXT_LEN - 1;
		plan_info.planid = pgsm_hash_string(plan_info.plan_text, plan_info.plan_len);
		plan_ptr = &plan_info;
	}

	if (queryId != INT64CONST(0) && queryDesc->totaltime && pgsm_enabled(nesting_level))
	{
		pgsmQueryStats *stats;
		struct rusage rusage_end;
		SysInfo		sys_info;
		int64		planid = plan_ptr ? plan_ptr->planid : 0;

		stats = pgsm_get_query_stats(queryId, planid, queryDesc->sourceText, queryDesc->operation);

		if (stats->key.planid == 0 && planid != 0)
			stats->key.planid = planid;

		/*
		 * Make sure stats accumulation is done.  (Note: it's okay if several
		 * levels of hook all do this.)
		 */
		InstrEndLoop(queryDesc->totaltime);

		getrusage(RUSAGE_SELF, &rusage_end);
		sys_info.utime = time_diff(rusage_end.ru_utime, rusage_start.ru_utime);
		sys_info.stime = time_diff(rusage_end.ru_stime, rusage_start.ru_stime);

		stats->counters.info.cmd_type = queryDesc->operation;

		pgsm_update_counters(&stats->counters,	/* counters */
							 plan_ptr,	/* PlanInfo */
							 &sys_info, /* SysInfo */
							 0, /* plan_total_time */
							 queryDesc->totaltime->total * 1000.0,	/* exec_total_time */
							 queryDesc->estate->es_processed,	/* rows */
							 &queryDesc->totaltime->bufusage,	/* bufusage */
							 &queryDesc->totaltime->walusage,	/* walusage */
#if PG_VERSION_NUM >= 150000
							 queryDesc->estate->es_jit ? &queryDesc->estate->es_jit->instr : NULL,	/* jitusage */
#else
							 NULL,
#endif
#if PG_VERSION_NUM >= 180000
							 queryDesc->estate->es_parallel_workers_to_launch,	/* parallel_workers_to_launch */
							 queryDesc->estate->es_parallel_workers_launched);	/* parallel_workers_launched */
#else
							 0, /* parallel_workers_to_launch */
							 0);	/* parallel_workers_launched */
#endif


		pgsm_store(stats);

		memset(&stats->counters, 0, sizeof(stats->counters));
		num_relations = 0;
	}

	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);

	pgsm_delete_query_stats(queryDesc->plannedstmt->queryId);
}

static PlannedStmt *
pgsm_planner_hook(Query *parse, const char *query_string, int cursorOptions, ParamListInfo boundParams)
{
	PlannedStmt *result;
	int64		queryId = parse->queryId;

	/*
	 * We can't process the query if no query_string is provided, as
	 * pgsm_store needs it.  We also ignore query without queryid, as it would
	 * be treated as a utility statement, which may not be the case.
	 *
	 * Note that planner_hook can be called from the planner itself, so we
	 * have a specific nesting level for the planner.  However, utility
	 * commands containing optimizable statements can also call the planner,
	 * same for regular DML (for instance for underlying foreign key queries).
	 * So testing the planner nesting level only is not enough to detect real
	 * top level planner call.
	 */

	bool		enabled;
#if PG_VERSION_NUM >= 170000
	enabled = pgsm_enabled(nesting_level);
#else
	enabled = pgsm_enabled(plan_nested_level + nesting_level);
#endif

	if (enabled && pgsm_track_planning && query_string && queryId != INT64CONST(0))
	{
		pgsmQueryStats *stats = NULL;
		instr_time	start;
		instr_time	duration;
		BufferUsage bufusage_start;
		BufferUsage bufusage;
		WalUsage	walusage_start;
		WalUsage	walusage;

		/* We need to track buffer usage as the planner can access them. */
		bufusage_start = pgBufferUsage;

		/*
		 * Similarly the planner could write some WAL records in some cases
		 * (e.g. setting a hint bit with those being WAL-logged)
		 */
		walusage_start = pgWalUsage;
		INSTR_TIME_SET_CURRENT(start);

		stats = pgsm_get_query_stats(queryId, 0, query_string, parse->commandType);

#if PG_VERSION_NUM >= 170000
		nesting_level++;
#else
		plan_nested_level++;
#endif
		PG_TRY();
		{
			/*
			 * If there is a previous installed hook, then assume it's going
			 * to call standard_planner() function, otherwise we call the
			 * function here. This is to avoid calling standard_planner()
			 * function twice, since it modifies the first argument (Query *),
			 * the second call would trigger an assertion failure.
			 */
			if (planner_hook_next)
				result = planner_hook_next(parse, query_string, cursorOptions, boundParams);
			else
				result = standard_planner(parse, query_string, cursorOptions, boundParams);
		}
		PG_FINALLY();
		{
#if PG_VERSION_NUM >= 170000
			nesting_level--;
#else
			plan_nested_level--;
#endif
		}
		PG_END_TRY();

		INSTR_TIME_SET_CURRENT(duration);
		INSTR_TIME_SUBTRACT(duration, start);

		/* calc differences of buffer counters. */
		memset(&bufusage, 0, sizeof(BufferUsage));
		BufferUsageAccumDiff(&bufusage, &pgBufferUsage, &bufusage_start);

		/* calc differences of WAL counters. */
		memset(&walusage, 0, sizeof(WalUsage));
		WalUsageAccumDiff(&walusage, &pgWalUsage, &walusage_start);

		/* The plan details are captured when the query finishes */
		if (stats)
			pgsm_update_counters(&stats->counters,	/* counters */
								 NULL,	/* PlanInfo */
								 NULL,	/* SysInfo */
								 INSTR_TIME_GET_MILLISEC(duration), /* plan_total_time */
								 0, /* exec_total_time */
								 0, /* rows */
								 &bufusage, /* bufusage */
								 &walusage, /* walusage */
								 NULL,	/* jitusage */
								 0, /* parallel_workers_to_launch */
								 0);	/* parallel_workers_launched */
	}
	else
	{
		/*
		 * Even though we're not tracking plan time for this statement, we
		 * must still increment the nesting level, to ensure that functions
		 * evaluated during planning are not seen as top-level calls.
		 *
		 * If there is a previous installed hook, then assume it's going to
		 * call standard_planner() function, otherwise we call the function
		 * here. This is to avoid calling standard_planner() function twice,
		 * since it modifies the first argument (Query *), the second call
		 * would trigger an assertion failure.
		 */

#if PG_VERSION_NUM >= 170000
		nesting_level++;
#else
		plan_nested_level++;
#endif
		PG_TRY();
		{
			if (planner_hook_next)
				result = planner_hook_next(parse, query_string, cursorOptions, boundParams);
			else
				result = standard_planner(parse, query_string, cursorOptions, boundParams);
		}
		PG_FINALLY();
		{
#if PG_VERSION_NUM >= 170000
			nesting_level--;
#else
			plan_nested_level--;
#endif
		}
		PG_END_TRY();

	}
	return result;
}

/*
 * ProcessUtility hook
 */
static void
pgsm_ProcessUtility(PlannedStmt *pstmt, const char *queryString,
					bool readOnlyTree,
					ProcessUtilityContext context,
					ParamListInfo params, QueryEnvironment *queryEnv,
					DestReceiver *dest,
					QueryCompletion *qc)

{
	Node	   *parsetree = pstmt->utilityStmt;
	int64		queryId = pstmt->queryId;
	bool		enabled = pgsm_track_utility && pgsm_enabled(nesting_level);

	/*
	 * Force utility statements to get queryId zero.  We do this even in cases
	 * where the statement contains an optimizable statement for which a
	 * queryId could be derived (such as EXPLAIN or DECLARE CURSOR).  For such
	 * cases, runtime control will first go through ProcessUtility and then
	 * the executor, and we don't want the executor hooks to do anything,
	 * since we are already measuring the statement's costs at the utility
	 * level.
	 */
	if (enabled)
		pstmt->queryId = INT64CONST(0);

	/*
	 * If it's an EXECUTE statement, we don't track it and don't increment the
	 * nesting level.  This allows the cycles to be charged to the underlying
	 * PREPARE instead (by the Executor hooks), which is much more useful.
	 *
	 * We also don't track execution of PREPARE.  If we did, we would get one
	 * hash table entry for the PREPARE (with hash calculated from the query
	 * string), and then a different one with the same query string (but hash
	 * calculated from the query tree) would be used to accumulate costs of
	 * ensuing EXECUTEs.  This would be confusing.  Since PREPARE doesn't
	 * actually run the planner (only parse+rewrite), its costs are generally
	 * pretty negligible and it seems okay to just ignore it.
	 *
	 * Likewise, we don't track execution of DEALLOCATE.
	 */
	if (enabled &&
		!IsA(parsetree, ExecuteStmt) &&
		!IsA(parsetree, PrepareStmt) &&
		!IsA(parsetree, DeallocateStmt))
	{
		const char *query_text;
		char	   *store_text;
		int			location = pstmt->stmt_location;
		int			query_len = pstmt->stmt_len;
		int			cmd_type = pstmt->commandType;
		instr_time	start;
		instr_time	duration;
		uint64		rows;
		struct rusage rusage_end;
		SysInfo		sys_info;
		BufferUsage bufusage;
		BufferUsage bufusage_start = pgBufferUsage;
		WalUsage	walusage;
		WalUsage	walusage_start = pgWalUsage;
		pgsmQueryStats stats = {0};
		pgsmQueryExecInfo info;

		getrusage(RUSAGE_SELF, &rusage_start);

		/*
		 * Create a query execution info before utility statement execution
		 * because statement may change the data itself and for statistics we
		 * need to know this data at the statement execution start time.
		 */
		pgsm_fill_query_exec_info(&info);

		INSTR_TIME_SET_CURRENT(start);
		nesting_level++;

		PG_TRY();
		{
			if (prev_ProcessUtility)
				prev_ProcessUtility(pstmt, queryString,
									readOnlyTree,
									context, params, queryEnv,
									dest,
									qc);
			else
				standard_ProcessUtility(pstmt, queryString,
										readOnlyTree,
										context, params, queryEnv,
										dest,
										qc);
		}
		PG_FINALLY();
		{
			nesting_level--;
		}
		PG_END_TRY();

		/*
		 * CAUTION: do not access the *pstmt data structure again below here.
		 * If it was a ROLLBACK or similar, that data structure may have been
		 * freed.  We must copy everything we still need into local variables,
		 * which we did above.
		 *
		 * For the same reason, we can't risk restoring pstmt->queryId to its
		 * former value, which'd otherwise be a good idea.
		 */

		getrusage(RUSAGE_SELF, &rusage_end);
		sys_info.utime = time_diff(rusage_end.ru_utime, rusage_start.ru_utime);
		sys_info.stime = time_diff(rusage_end.ru_stime, rusage_start.ru_stime);

		INSTR_TIME_SET_CURRENT(duration);
		INSTR_TIME_SUBTRACT(duration, start);

		rows = (qc && (qc->commandTag == CMDTAG_COPY ||
					   qc->commandTag == CMDTAG_FETCH ||
					   qc->commandTag == CMDTAG_SELECT ||
					   qc->commandTag == CMDTAG_REFRESH_MATERIALIZED_VIEW))
			? qc->nprocessed
			: 0;

		/* calc differences of WAL counters. */
		memset(&walusage, 0, sizeof(WalUsage));
		WalUsageAccumDiff(&walusage, &pgWalUsage, &walusage_start);

		/* calc differences of buffer counters. */
		memset(&bufusage, 0, sizeof(BufferUsage));
		BufferUsageAccumDiff(&bufusage, &pgBufferUsage, &bufusage_start);

		query_text = CleanQuerytext(queryString, &location, &query_len);

		/* Make it null terminated */
		store_text = pnstrdup(query_text, query_len);

		pgsm_fill_query_stats(&stats, &info, queryId, 0,
							  get_pgsm_query_id_hash(query_text, query_len),
							  store_text, cmd_type);

		/* The plan details are captured when the query finishes */
		pgsm_update_counters(&stats.counters,	/* counters */
							 NULL,	/* PlanInfo */
							 &sys_info, /* SysInfo */
							 0, /* plan_total_time */
							 INSTR_TIME_GET_MILLISEC(duration), /* exec_total_time */
							 rows,	/* rows */
							 &bufusage, /* bufusage */
							 &walusage, /* walusage */
							 NULL,	/* jitusage */
							 0, /* parallel_workers_to_launch */
							 0);	/* parallel_workers_launched */

		pgsm_store(&stats);

		pfree(store_text);
	}
	else
	{
		/*
		 * Even though we're not tracking execution time for this statement,
		 * we must still increment the nesting level, to ensure that functions
		 * evaluated within it are not seen as top-level calls.  But don't do
		 * so for EXECUTE; that way, when control reaches pgss_planner or
		 * pgss_ExecutorStart, we will treat the costs as top-level if
		 * appropriate.  Likewise, don't bump for PREPARE, so that parse
		 * analysis will treat the statement as top-level if appropriate.
		 *
		 * Likewise, we don't track execution of DEALLOCATE.
		 *
		 * To be absolutely certain we don't mess up the nesting level,
		 * evaluate the bump_level condition just once.
		 */

#if PG_VERSION_NUM >= 170000
		bool		bump_level =
			!IsA(parsetree, ExecuteStmt) &&
			!IsA(parsetree, PrepareStmt) &&
			!IsA(parsetree, DeallocateStmt);

		if (bump_level)
			nesting_level++;

		PG_TRY();
		{
#endif
			if (prev_ProcessUtility)
				prev_ProcessUtility(pstmt, queryString,
									readOnlyTree,
									context, params, queryEnv,
									dest,
									qc);
			else
				standard_ProcessUtility(pstmt, queryString,
										readOnlyTree,
										context, params, queryEnv,
										dest,
										qc);

#if PG_VERSION_NUM >= 170000
		}
		PG_FINALLY();
		{
			if (bump_level)
				nesting_level--;
		}
		PG_END_TRY();
#endif
	}
}

/*
 * Given an arbitrarily long query string, produce a hash for the purposes of
 * identifying the query, without normalizing constants.  Used when hashing
 * utility statements.
 */
static int64
pgsm_hash_string(const char *str, int len)
{
	return (int64) hash_bytes_extended((const unsigned char *) str, len, 0);
}

/*
 * Set backend-level cached information.
 */
static void
pgsm_set_cached_info(void)
{
	if (client_ip == PGSM_INVALID_IP)
		client_ip = pg_get_client_addr();

	if (datname[0] == '\0' && IsTransactionState())
	{
		char	   *name = get_database_name(MyDatabaseId);

		if (name)
		{
			strlcpy(datname, name, NAMEDATALEN);
			pfree(name);
		}
	}
}

/*
 * Fill the query execution info with the current statement execution data.
 * Some data may be changed by statement execution itself, but for
 * statistics we need this data state at the statement execution start time.
 */
static void
pgsm_fill_query_exec_info(pgsmQueryExecInfo *info)
{
	int			sec_ctx;

	/*
	 * Get the user ID. Let's use this instead of GetUserID as this won't
	 * throw an assertion in case of an error.
	 */
	GetUserIdAndSecContext(&info->userid, &sec_ctx);

	if (application_name && *application_name)
		strlcpy(info->appname, application_name, NAMEDATALEN);
	else
		strlcpy(info->appname, "unknown", NAMEDATALEN);

	info->username[0] = '\0';
	if (IsTransactionState())
	{
		char	   *username = GetUserNameFromId(info->userid, true);

		if (username)
		{
			strlcpy(info->username, username, NAMEDATALEN);
			pfree(username);
		}
	}
}

static uint
pg_get_client_addr(void)
{
	char		remote_host[NI_MAXHOST];
	int			ret;

	if (!MyProcPort)
		return ntohl(inet_addr("127.0.0.1"));

	ret = pg_getnameinfo_all(&MyProcPort->raddr.addr,
							 MyProcPort->raddr.salen,
							 remote_host, sizeof(remote_host),
							 NULL, 0,
							 NI_NUMERICHOST | NI_NUMERICSERV);
	if (ret != 0)
		return ntohl(inet_addr("127.0.0.1"));

	if (strcmp(remote_host, "[local]") == 0)
		return ntohl(inet_addr("127.0.0.1"));

	return ntohl(inet_addr(remote_host));
}

static void
pgsm_update_counters(Counters *counters,
					 const PlanInfo *plan_info,
					 const SysInfo *sys_info,
					 double plan_total_time,
					 double exec_total_time,
					 uint64 rows,
					 const BufferUsage *bufusage,
					 const WalUsage *walusage,
					 const struct JitInstrumentation *jitusage,
					 int parallel_workers_to_launch,
					 int parallel_workers_launched)
{
	/*
	 * Only the update totals here, min/max/mean will be computed in
	 * pgsm_merge_counters.
	 */
	counters->plantime.total_time += plan_total_time;
	counters->time.total_time += exec_total_time;

	if (plan_info && !counters->planinfo.plan_text[0])
	{
		counters->planinfo.planid = plan_info->planid;
		counters->planinfo.plan_len = plan_info->plan_len;
		strlcpy(counters->planinfo.plan_text, plan_info->plan_text, PLAN_TEXT_LEN);
	}

	counters->calls.rows += rows;

	if (bufusage)
	{
		counters->blocks.shared_blks_hit += bufusage->shared_blks_hit;
		counters->blocks.shared_blks_read += bufusage->shared_blks_read;
		counters->blocks.shared_blks_dirtied += bufusage->shared_blks_dirtied;
		counters->blocks.shared_blks_written += bufusage->shared_blks_written;
		counters->blocks.local_blks_hit += bufusage->local_blks_hit;
		counters->blocks.local_blks_read += bufusage->local_blks_read;
		counters->blocks.local_blks_dirtied += bufusage->local_blks_dirtied;
		counters->blocks.local_blks_written += bufusage->local_blks_written;
		counters->blocks.temp_blks_read += bufusage->temp_blks_read;
		counters->blocks.temp_blks_written += bufusage->temp_blks_written;

#if PG_VERSION_NUM >= 170000
		counters->blocks.shared_blk_read_time += INSTR_TIME_GET_MILLISEC(bufusage->shared_blk_read_time);
		counters->blocks.shared_blk_write_time += INSTR_TIME_GET_MILLISEC(bufusage->shared_blk_write_time);
		counters->blocks.local_blk_read_time += INSTR_TIME_GET_MILLISEC(bufusage->local_blk_read_time);
		counters->blocks.local_blk_write_time += INSTR_TIME_GET_MILLISEC(bufusage->local_blk_write_time);
#else
		counters->blocks.shared_blk_read_time += INSTR_TIME_GET_MILLISEC(bufusage->blk_read_time);
		counters->blocks.shared_blk_write_time += INSTR_TIME_GET_MILLISEC(bufusage->blk_write_time);
#endif

#if PG_VERSION_NUM >= 150000
		counters->blocks.temp_blk_read_time += INSTR_TIME_GET_MILLISEC(bufusage->temp_blk_read_time);
		counters->blocks.temp_blk_write_time += INSTR_TIME_GET_MILLISEC(bufusage->temp_blk_write_time);
#endif
	}

	if (sys_info)
	{
		counters->sysinfo.utime += sys_info->utime;
		counters->sysinfo.stime += sys_info->stime;
	}
	if (walusage)
	{
		counters->walusage.wal_records += walusage->wal_records;
		counters->walusage.wal_fpi += walusage->wal_fpi;
		counters->walusage.wal_bytes += walusage->wal_bytes;
#if PG_VERSION_NUM >= 180000
		counters->walusage.wal_buffers_full += walusage->wal_buffers_full;
#endif
	}
	if (jitusage)
	{
		counters->jitinfo.jit_functions += jitusage->created_functions;
		counters->jitinfo.jit_generation_time += INSTR_TIME_GET_MILLISEC(jitusage->generation_counter);

		if (INSTR_TIME_GET_MILLISEC(jitusage->inlining_counter))
			counters->jitinfo.jit_inlining_count++;
		counters->jitinfo.jit_inlining_time += INSTR_TIME_GET_MILLISEC(jitusage->inlining_counter);

		if (INSTR_TIME_GET_MILLISEC(jitusage->optimization_counter))
			counters->jitinfo.jit_optimization_count++;
		counters->jitinfo.jit_optimization_time += INSTR_TIME_GET_MILLISEC(jitusage->optimization_counter);

		if (INSTR_TIME_GET_MILLISEC(jitusage->emission_counter))
			counters->jitinfo.jit_emission_count++;
		counters->jitinfo.jit_emission_time += INSTR_TIME_GET_MILLISEC(jitusage->emission_counter);

#if PG_VERSION_NUM >= 170000
		if (INSTR_TIME_GET_MILLISEC(jitusage->deform_counter))
			counters->jitinfo.jit_deform_count++;
		counters->jitinfo.jit_deform_time += INSTR_TIME_GET_MILLISEC(jitusage->deform_counter);
#endif
	}

	/* parallel worker counters */
	counters->parallel_workers_to_launch += parallel_workers_to_launch;
	counters->parallel_workers_launched += parallel_workers_launched;
}

/*
 * Merges source counters into destination counters.
 */
static void
pgsm_merge_counters(Counters *dst, const Counters *src)
{
	int			index;

	/* plan stats: fold src as a single sample */
	dst->plancalls.calls += 1;
	dst->plantime.total_time += src->plantime.total_time;
	if (dst->plancalls.calls == 1)
	{
		dst->plantime.min_time = src->plantime.total_time;
		dst->plantime.max_time = src->plantime.total_time;
		dst->plantime.mean_time = src->plantime.total_time;
	}
	else
	{
		double		old_mean = dst->plantime.mean_time;

		dst->plantime.mean_time += (src->plantime.total_time - old_mean) / dst->plancalls.calls;
		dst->plantime.sum_var_time += (src->plantime.total_time - old_mean) * (src->plantime.total_time - dst->plantime.mean_time);

		if (dst->plantime.min_time > src->plantime.total_time)
			dst->plantime.min_time = src->plantime.total_time;
		if (dst->plantime.max_time < src->plantime.total_time)
			dst->plantime.max_time = src->plantime.total_time;
	}

	/* exec stats: fold src as a single sample */
	dst->calls.calls += 1;
	dst->time.total_time += src->time.total_time;
	if (dst->calls.calls == 1)
	{
		dst->time.min_time = src->time.total_time;
		dst->time.max_time = src->time.total_time;
		dst->time.mean_time = src->time.total_time;
	}
	else
	{
		double		old_mean = dst->time.mean_time;

		dst->time.mean_time += (src->time.total_time - old_mean) / dst->calls.calls;
		dst->time.sum_var_time += (src->time.total_time - old_mean) * (src->time.total_time - dst->time.mean_time);

		if (dst->time.min_time > src->time.total_time)
			dst->time.min_time = src->time.total_time;
		if (dst->time.max_time < src->time.total_time)
			dst->time.max_time = src->time.total_time;
	}

	index = get_histogram_bucket(src->time.total_time);
	dst->resp_calls[index]++;

	/* copy the plan text once */
	if (!dst->planinfo.plan_text[0])
	{
		dst->planinfo.planid = src->planinfo.planid;
		dst->planinfo.plan_len = src->planinfo.plan_len;
		strlcpy(dst->planinfo.plan_text, src->planinfo.plan_text, PLAN_TEXT_LEN);
	}

	/* error info */
	dst->error.elevel = src->error.elevel;
	strlcpy(dst->error.sqlcode, src->error.sqlcode, SQLCODE_LEN);
	strlcpy(dst->error.message, src->error.message, ERROR_MESSAGE_LEN);

	/* additive counters */
	dst->calls.rows += src->calls.rows;

	dst->blocks.shared_blks_hit += src->blocks.shared_blks_hit;
	dst->blocks.shared_blks_read += src->blocks.shared_blks_read;
	dst->blocks.shared_blks_dirtied += src->blocks.shared_blks_dirtied;
	dst->blocks.shared_blks_written += src->blocks.shared_blks_written;
	dst->blocks.local_blks_hit += src->blocks.local_blks_hit;
	dst->blocks.local_blks_read += src->blocks.local_blks_read;
	dst->blocks.local_blks_dirtied += src->blocks.local_blks_dirtied;
	dst->blocks.local_blks_written += src->blocks.local_blks_written;
	dst->blocks.temp_blks_read += src->blocks.temp_blks_read;
	dst->blocks.temp_blks_written += src->blocks.temp_blks_written;

	dst->blocks.shared_blk_read_time += src->blocks.shared_blk_read_time;
	dst->blocks.shared_blk_write_time += src->blocks.shared_blk_write_time;
	dst->blocks.local_blk_read_time += src->blocks.local_blk_read_time;
	dst->blocks.local_blk_write_time += src->blocks.local_blk_write_time;
	dst->blocks.temp_blk_read_time += src->blocks.temp_blk_read_time;
	dst->blocks.temp_blk_write_time += src->blocks.temp_blk_write_time;

	dst->sysinfo.utime += src->sysinfo.utime;
	dst->sysinfo.stime += src->sysinfo.stime;

	dst->walusage.wal_records += src->walusage.wal_records;
	dst->walusage.wal_fpi += src->walusage.wal_fpi;
	dst->walusage.wal_bytes += src->walusage.wal_bytes;
	dst->walusage.wal_buffers_full += src->walusage.wal_buffers_full;

	dst->jitinfo.jit_functions += src->jitinfo.jit_functions;
	dst->jitinfo.jit_generation_time += src->jitinfo.jit_generation_time;
	dst->jitinfo.jit_inlining_count += src->jitinfo.jit_inlining_count;
	dst->jitinfo.jit_inlining_time += src->jitinfo.jit_inlining_time;
	dst->jitinfo.jit_optimization_count += src->jitinfo.jit_optimization_count;
	dst->jitinfo.jit_optimization_time += src->jitinfo.jit_optimization_time;
	dst->jitinfo.jit_emission_count += src->jitinfo.jit_emission_count;
	dst->jitinfo.jit_emission_time += src->jitinfo.jit_emission_time;
	dst->jitinfo.jit_deform_count += src->jitinfo.jit_deform_count;
	dst->jitinfo.jit_deform_time += src->jitinfo.jit_deform_time;

	/* parallel worker counters */
	dst->parallel_workers_to_launch += src->parallel_workers_to_launch;
	dst->parallel_workers_launched += src->parallel_workers_launched;
}

static void
pgsm_store_error(const char *query, const ErrorData *edata)
{
	pgsmQueryStats stats = {0};
	pgsmQueryExecInfo info;
	int			len = strlen(query);

	pgsm_fill_query_exec_info(&info);
	pgsm_fill_query_stats(&stats, &info,
						  pgsm_hash_string(query, len),
						  0,
						  get_pgsm_query_id_hash(query, len),
						  query, CMD_UNKNOWN);

	stats.counters.error.elevel = edata->elevel;
	strlcpy(stats.counters.error.message, edata->message, ERROR_MESSAGE_LEN);
	strlcpy(stats.counters.error.sqlcode, unpack_sql_state(edata->sqlerrcode), SQLCODE_LEN);

	pgsm_store(&stats);
}

/*
 * Return pgsm local memory context.
 *
 * This context is used to store intermediate query statistics before it will be added
 * to the buckets in shared memory.
 */
static MemoryContext
pgsm_memory_context(void)
{
	Assert(IsTransactionState());

	if (PgsmMemoryContext == NULL)
	{
		/*
		 * We expect top transaction context to be available in any possible
		 * scenario. CurrentMemoryContext here is just a failsafe mechanism,
		 * it should never happen.
		 */
		MemoryContext parent = IsTransactionState() ? TopTransactionContext
			: CurrentMemoryContext;

		PgsmMemoryContext = AllocSetContextCreate(parent,
												  "pg_stat_monitor local store",
												  ALLOCSET_START_SMALL_SIZES);
		MemoryContextRegisterResetCallback(PgsmMemoryContext,
										   &mem_cxt_reset_callback);
		lentries = NIL;
	}

	return PgsmMemoryContext;
}

/*
 * Function to add a new pgsmQueryStats structure to the backend-local list.
 */
static pgsmQueryStats *
pgsm_add_query_stats(int64 queryid, int64 planid, int64 pgsm_query_id, const char *query_text, int query_len, CmdType cmd_type)
{
	pgsmQueryStats *stats;
	pgsmQueryExecInfo info;
	MemoryContext oldctx;
	char	   *store_text;

	pgsm_fill_query_exec_info(&info);

	/* Create the stats and own the query text in the pgsm memory context */
	oldctx = MemoryContextSwitchTo(pgsm_memory_context());
	stats = palloc0_object(pgsmQueryStats);
	store_text = pnstrdup(query_text, query_len);

	pgsm_fill_query_stats(stats, &info, queryid, planid, pgsm_query_id, store_text, cmd_type);
	lentries = lappend(lentries, stats);
	MemoryContextSwitchTo(oldctx);

	return stats;
}

/*
 * Populate non-counter fields of a pgsmQueryStats.
 */
static void
pgsm_fill_query_stats(pgsmQueryStats *stats, const pgsmQueryExecInfo *info, int64 queryid, int64 planid, int64 pgsm_query_id, const char *query_text, CmdType cmd_type)
{
	pgsm_set_cached_info();

	stats->subxid = IsTransactionState() ? GetCurrentSubTransactionId()
		: InvalidSubTransactionId;

	if (pgsm_track_application_names)
	{
		stats->key.appid = pgsm_hash_string(info->appname, strlen(info->appname));
	}
	stats->key.ip = client_ip;
	stats->key.planid = planid;
	stats->key.dbid = MyDatabaseId;
	stats->key.queryid = queryid;
	stats->key.parentid = 0;
	stats->key.userid = info->userid;

	stats->pgsm_query_id = pgsm_query_id;
	stats->counters.info.cmd_type = cmd_type;
	stats->query = unconstify(char *, query_text);

	strlcpy(stats->appname, info->appname, NAMEDATALEN);
	strlcpy(stats->username, info->username, NAMEDATALEN);

#if PG_VERSION_NUM >= 170000
	stats->key.toplevel = (nesting_level == 0);
#else
	stats->key.toplevel = (nesting_level + plan_nested_level == 0);
#endif
}

/*
 * Function to delete a pgsmQueryStats structure from the local list.
 */
static void
pgsm_delete_query_stats(uint64 queryid)
{
	pgsmQueryStats *stats;
	ListCell   *lc;

	if (lentries == NIL)
		return;

	stats = (pgsmQueryStats *) llast(lentries);
	if (stats->key.queryid == queryid)
	{
		lentries = list_delete_last(lentries);
		pfree(stats->query);
		pfree(stats);
		return;
	}

	/*
	 * The rest of the code is just paranoia. In theory this list is a stack,
	 * and we always want to remove the last item. Similarly, in the getter
	 * method we are always looking for the last item.
	 */

	foreach(lc, lentries)
	{
		stats = lfirst(lc);
		if (stats->key.queryid == queryid)
		{
			lentries = list_delete_cell(lentries, lc);
			pfree(stats->query);
			pfree(stats);
			return;
		}
	}
}

/*
 * Function to get a pgsmQueryStats structure from the local list.
 */
static pgsmQueryStats *
pgsm_get_query_stats(int64 queryid, int64 planid, const char *query_text, CmdType cmd_type)
{
	pgsmQueryStats *stats;
	int			query_len;

	Assert(query_text != NULL);

	if (lentries != NIL)
	{
		ListCell   *lc;

		/* First bet is on the last item */
		stats = (pgsmQueryStats *) llast(lentries);
		if (stats->key.queryid == queryid)
			return stats;

		foreach(lc, lentries)
		{
			stats = lfirst(lc);
			if (stats->key.queryid == queryid)
				return stats;
		}
	}

	query_len = strlen(query_text);
	stats = pgsm_add_query_stats(queryid, planid,
								 get_pgsm_query_id_hash(query_text, query_len),
								 query_text, query_len, cmd_type);

	return stats;
}

static void
pgsm_cleanup_callback(void *arg)
{
	PgsmMemoryContext = NULL;
	lentries = NIL;
}

/*
 * On subtransaction abort, discard any in-flight local stats that belong to the
 * aborting subtransaction.
 */
static void
pgsm_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
					  SubTransactionId parentSubid, void *arg)
{
	ListCell   *lc;

	if (event != SUBXACT_EVENT_ABORT_SUB)
		return;

	foreach(lc, lentries)
	{
		pgsmQueryStats *stats = lfirst(lc);

		/*
		 * Prune entries stamped by the aborting subxact. Using >= is
		 * defensive (cleanup everything that is not yet pruned)
		 */
		if (stats->subxid >= mySubid)
		{
			lentries = foreach_delete_current(lentries, lc);
			pfree(stats->query);
			pfree(stats);
		}
	}
}

/*
 * Store some statistics for a statement.
 *
 * If queryId is 0 then this is a utility statement and we should compute
 * a suitable queryId internally.
 *
 * If jstate is not NULL then we're trying to create an entry for which
 * we have no statistics as yet; we just want to record the normalized
 * query string.  total_time, rows, bufusage are ignored in this case.
 */
static void
pgsm_store(const pgsmQueryStats *stats)
{
	pgsmEntry  *entry;
	pgsmSharedState *pgsm;
	bool		found;
	uint64		bucketid;
	uint64		prev_bucket_id;
	pgsmHashKey key = stats->key;
	char	   *query = stats->query;
	char		comments[COMMENTS_LEN];
	TimestampTz reset_timestamp;

	/* Safety check... */
	if (!IsSystemInitialized())
		return;

	pgsm = pgsm_get_ss();

	prev_bucket_id = pg_atomic_read_u64(&pgsm->current_wbucket);
	bucketid = get_next_wbucket(pgsm);

	key.bucket_id = bucketid;

	/* Let's do all the leg work here before we acquire any locks */

	if (pgsm_extract_comments)
		extract_query_comments(query, comments, sizeof(comments));

	/* Update parent id if needed */
	if (pgsm_track == PGSM_TRACK_ALL && nesting_level > 0 && nesting_level < max_nesting_level)
	{
		key.parentid = nested_queryids[nesting_level - 1];
	}
	else
	{
		key.parentid = INT64CONST(0);
	}

	/*
	 * Acquire a share lock to start with. We'd have to acquire exclusive if
	 * we need to create the entry.
	 */
	pgsm_lock_aquire(pgsm, LW_SHARED);
	entry = (pgsmEntry *) hash_search(get_pgsmHash(), &key, HASH_FIND, &found);

	if (!entry)
	{
		dsa_pointer dsa_query_pointer;
		dsa_area   *query_dsa_area;
		char	   *query_buff;
		int			query_len = strlen(query);

		/* New query, truncate length if necessary. */
		if (query_len > pgsm_query_max_len)
			query_len = pg_mbcliplen(query, query_len, pgsm_query_max_len);

		/* Save the query text in raw dsa area */
		query_dsa_area = get_dsa_area_for_query_text();
		dsa_query_pointer = dsa_allocate_extended(query_dsa_area, query_len + 1, DSA_ALLOC_NO_OOM);
		if (!DsaPointerIsValid(dsa_query_pointer))
		{
			pgsm_lock_release(pgsm);
			return;
		}

		/*
		 * Get the memory address from DSA pointer and copy the query text in
		 * local variable
		 */
		query_buff = dsa_get_address(query_dsa_area, dsa_query_pointer);
		memcpy(query_buff, query, query_len);
		query_buff[query_len] = '\0';

		pgsm_lock_release(pgsm);
		pgsm_lock_aquire(pgsm, LW_EXCLUSIVE);

		/* OK to create a new hashtable entry */
		entry = hash_entry_alloc(pgsm, &key);

		if (entry == NULL)
		{
			pgsm_lock_release(pgsm);

			dsa_free(query_dsa_area, dsa_query_pointer);

			/*
			 * Out of memory; report only if the state has changed now.
			 * Otherwise we risk filling up the log file with these message.
			 */
			if (!pgsm->pgsm_oom)
			{
				pgsm->pgsm_oom = true;

				disable_error_capture = true;
				ereport(WARNING,
						errcode(ERRCODE_OUT_OF_MEMORY),
						errmsg("[pg_stat_monitor] pgsm_store: Hash table is out of memory and can no longer store queries!"),
						errdetail("You may reset the view or when the buckets are deallocated, pg_stat_monitor will resume saving " \
								  "queries. Alternatively, try increasing the value of pg_stat_monitor.pgsm_max."));
				disable_error_capture = false;
			}

			return;
		}
		else
		{
			/* If we got a new entry, reset the oom value false */
			pgsm->pgsm_oom = false;
		}

		/* If we already have the pointer set, free this one */
		if (DsaPointerIsValid(entry->query))
			dsa_free(query_dsa_area, dsa_query_pointer);
		else
			entry->query = dsa_query_pointer;

		entry->pgsm_query_id = stats->pgsm_query_id;
		entry->counters.info.cmd_type = stats->counters.info.cmd_type;
		entry->counters.info.parent_query = InvalidDsaPointer;

		strlcpy(entry->datname, datname, sizeof(entry->datname));
		strlcpy(entry->username, stats->username, sizeof(entry->username));
	}

	/* Do work outside spinlock */
	if (bucketid != prev_bucket_id)
		reset_timestamp = GetCurrentTimestamp();

	SpinLockAcquire(&entry->mutex);

	/*
	 * Start collecting data for next bucket and reset all counters and
	 * timestamps.
	 */
	if (bucketid != prev_bucket_id)
	{
		memset(&entry->counters, 0, sizeof(Counters));
		entry->counters.info.cmd_type = stats->counters.info.cmd_type;
		entry->stats_since = reset_timestamp;
		entry->minmax_stats_since = reset_timestamp;
	}

	pgsm_merge_counters(&entry->counters, &stats->counters);

	/* copy the query metadata once */
	if (pgsm_extract_comments && comments[0] && !entry->counters.info.comments[0])
		strlcpy(entry->counters.info.comments, comments, COMMENTS_LEN);

	if (pgsm_track_application_names && stats->appname[0] != '\0' && !entry->counters.info.application_name[0])
		strlcpy(entry->counters.info.application_name, stats->appname, NAMEDATALEN);

	entry->counters.info.num_relations = num_relations;
	for (int i = 0; i < num_relations; i++)
		strlcpy(entry->counters.info.relations[i], relations[i], REL_LEN);

	if (nesting_level > 0 && nesting_level < max_nesting_level && key.parentid != 0 && pgsm_track == PGSM_TRACK_ALL)
	{
		if (!DsaPointerIsValid(entry->counters.info.parent_query))
		{
			/* If we have a parent query, store it in the raw dsa area */
			if (nested_query_txts[nesting_level - 1] && nested_query_txts[nesting_level - 1][0])
			{
				int			parent_query_len = strlen(nested_query_txts[nesting_level - 1]);
				dsa_area   *query_dsa_area = get_dsa_area_for_query_text();

				/*
				 * Use dsa_allocate_extended with DSA_ALLOC_NO_OOM flag, as we
				 * don't want to get an error if memory allocation fails.
				 */
				dsa_pointer qry = dsa_allocate_extended(query_dsa_area, parent_query_len + 1, DSA_ALLOC_NO_OOM);

				if (DsaPointerIsValid(qry))
				{
					char	   *qry_buff = dsa_get_address(query_dsa_area, qry);

					memcpy(qry_buff, nested_query_txts[nesting_level - 1], parent_query_len);
					qry_buff[parent_query_len] = '\0';
					/* store the dsa pointer for parent query text */
					entry->counters.info.parent_query = qry;
				}
			}
		}
	}
	else
	{
		Assert(!DsaPointerIsValid(entry->counters.info.parent_query));
	}

	SpinLockRelease(&entry->mutex);

	pgsm_lock_release(pgsm);
}

/*
 * Reset all statement statistics.
 */
Datum
pg_stat_monitor_reset(PG_FUNCTION_ARGS)
{
	pgsmSharedState *pgsm;

	/* Safety check... */
	if (!IsSystemInitialized())
		ereport(ERROR,
				errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				errmsg("pg_stat_monitor: must be loaded via shared_preload_libraries"));

	pgsm = pgsm_get_ss();
	pgsm_lock_aquire(pgsm, LW_EXCLUSIVE);
	hash_entry_dealloc(INVALID_BUCKET_ID);
	pgsm_lock_release(pgsm);
	PG_RETURN_VOID();
}

Datum
pg_stat_monitor_1_0(PG_FUNCTION_ARGS)
{
	pg_stat_monitor_internal(fcinfo, PGSM_V1_0, true);
	return (Datum) 0;
}

Datum
pg_stat_monitor_2_0(PG_FUNCTION_ARGS)
{
	pg_stat_monitor_internal(fcinfo, PGSM_V2_0, true);
	return (Datum) 0;
}

Datum
pg_stat_monitor_2_1(PG_FUNCTION_ARGS)
{
	pg_stat_monitor_internal(fcinfo, PGSM_V2_1, true);
	return (Datum) 0;
}

Datum
pg_stat_monitor_2_3(PG_FUNCTION_ARGS)
{
	pg_stat_monitor_internal(fcinfo, PGSM_V2_3, true);
	return (Datum) 0;
}

/*
  * Legacy entry point for pg_stat_monitor() API versions 1.0
  */
Datum
pg_stat_monitor(PG_FUNCTION_ARGS)
{
	pg_stat_monitor_internal(fcinfo, PGSM_V1_0, true);
	return (Datum) 0;
}

static bool
IsBucketValid(uint64 bucketid, TimestampTz now)
{
	long		secs;
	int			microsecs;
	pgsmSharedState *pgsm = pgsm_get_ss();

	TimestampDifference(pgsm->bucket_start_time[bucketid], now, &secs, &microsecs);

	return secs <= (int64) pgsm_bucket_time * pgsm_max_buckets;
}

/* Common code for all versions of pg_stat_monitor() */
static void
pg_stat_monitor_internal(FunctionCallInfo fcinfo,
						 pgsmVersion api_version,
						 bool showtext)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	bool		may_read_all_stats;
	TupleDesc	tupdesc;
	Tuplestorestate *tupstore;
	MemoryContext per_query_ctx;
	MemoryContext oldcontext;
	HASH_SEQ_STATUS hstat;
	TimestampTz now;
	uint64		current_bucket;
	pgsmEntry  *entry;
	pgsmSharedState *pgsm;
	int			expected_columns;

	may_read_all_stats = is_member_of_role(GetUserId(), ROLE_PG_READ_ALL_STATS);

	switch (api_version)
	{
		case PGSM_V1_0:
			expected_columns = PG_STAT_MONITOR_COLS_V1_0;
			break;
		case PGSM_V2_0:
			expected_columns = PG_STAT_MONITOR_COLS_V2_0;
			break;
		case PGSM_V2_1:
			expected_columns = PG_STAT_MONITOR_COLS_V2_1;
			break;
		case PGSM_V2_3:
			expected_columns = PG_STAT_MONITOR_COLS_V2_3;
			break;
		default:
			ereport(ERROR,
					errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					errmsg("[pg_stat_monitor] pg_stat_monitor_internal: Unknown API version"));
	}

	/* Disallow old api usage */
	if (api_version < PGSM_V2_0)
		ereport(ERROR,
				errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				errmsg("[pg_stat_monitor] pg_stat_monitor_internal: API version not supported."),
				errhint("Upgrade pg_stat_monitor extension"));
	/* Safety check... */
	if (!IsSystemInitialized())
		ereport(ERROR,
				errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				errmsg("[pg_stat_monitor] pg_stat_monitor_internal: Must be loaded via shared_preload_libraries."));

	/* Out of memory? */
	if (IsSystemOOM())
		ereport(WARNING,
				errcode(ERRCODE_OUT_OF_MEMORY),
				errmsg("[pg_stat_monitor] pg_stat_monitor_internal: Hash table is out of memory and can no longer store queries!"),
				errdetail("You may reset the view or when the buckets are deallocated, pg_stat_monitor will resume saving " \
						  "queries. Alternatively, try increasing the value of pg_stat_monitor.pgsm_max."));

	/* check to see if caller supports us returning a tuplestore */
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				errmsg("[pg_stat_monitor] pg_stat_monitor_internal: Set-valued function called in context that cannot accept a set."));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				errmsg("[pg_stat_monitor] pg_stat_monitor_internal: Materialize mode required, but it is not "
					   "allowed in this context."));

	/* Switch into long-lived context to construct returned data structures */
	per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
	oldcontext = MemoryContextSwitchTo(per_query_ctx);

	/* Build a tuple descriptor for our result type */
	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "[pg_stat_monitor] pg_stat_monitor_internal: Return type must be a row type.");

	if (tupdesc->natts != expected_columns)
		elog(ERROR, "[pg_stat_monitor] pg_stat_monitor_internal: Incorrect number of output arguments, received %d, required %d.", tupdesc->natts, expected_columns);

	tupstore = tuplestore_begin_heap(true, false, work_mem);
	rsinfo->returnMode = SFRM_Materialize;
	rsinfo->setResult = tupstore;
	rsinfo->setDesc = tupdesc;

	MemoryContextSwitchTo(oldcontext);

	pgsm = pgsm_get_ss();
	pgsm_lock_aquire(pgsm, LW_SHARED);
	hash_seq_init(&hstat, get_pgsmHash());

	now = GetCurrentTimestamp();
	current_bucket = pg_atomic_read_u64(&pgsm->current_wbucket);

	while ((entry = hash_seq_search(&hstat)) != NULL)
	{
		Datum		values[PG_STAT_MONITOR_COLS] = {0};
		bool		nulls[PG_STAT_MONITOR_COLS] = {0};
		int			i = 0;
		Counters	tmp;
		pgsmHashKey tmpkey;
		double		stddev;
		int64		queryid = entry->key.queryid;
		int64		bucketid = entry->key.bucket_id;
		Oid			dbid = entry->key.dbid;
		Oid			userid = entry->key.userid;
		uint32		ip = entry->key.ip;
		int64		planid = entry->key.planid;
		int64		pgsm_query_id = entry->pgsm_query_id;
		char	   *query_text;
		char	   *parent_query_text = NULL;
		bool		toplevel = entry->key.toplevel;

		/* Load the query text from dsa area */
		if (DsaPointerIsValid(entry->query))
		{
			dsa_area   *query_dsa_area;

			query_dsa_area = get_dsa_area_for_query_text();
			query_text = dsa_get_address(query_dsa_area, entry->query);
		}
		else
			query_text = "Query string not available";	/* Should never happen */

		/* copy counters to a local variable to keep locking time short */
		SpinLockAcquire(&entry->mutex);
		tmp = entry->counters;
		tmpkey = entry->key;
		SpinLockRelease(&entry->mutex);

		/*
		 * In case that query plan is enabled, there is no need to show 0
		 * planid query
		 */
		if (tmp.info.cmd_type == CMD_SELECT && pgsm_enable_query_plan && planid == 0)
			continue;

		if (!IsBucketValid(bucketid, now))
			continue;

		/* read the parent query text if any */
		if (tmpkey.parentid != INT64CONST(0))
		{
			if (DsaPointerIsValid(tmp.info.parent_query))
			{
				dsa_area   *query_dsa_area;

				query_dsa_area = get_dsa_area_for_query_text();
				parent_query_text = dsa_get_address(query_dsa_area, tmp.info.parent_query);
			}
			else
				parent_query_text = "parent query text not available";
		}

		/* bucketid at column number 0 */
		values[i++] = Int64GetDatumFast(bucketid);

		/* userid at column number 1 */
		values[i++] = ObjectIdGetDatum(userid);

		/* username at column number 2 */
		values[i++] = CStringGetTextDatum(entry->username);

		/* dbid at column number 3 */
		values[i++] = ObjectIdGetDatum(dbid);

		/* datname at column number 4 */
		values[i++] = CStringGetTextDatum(entry->datname);

		/*
		 * ip address at column number 5, Superusers or members of
		 * pg_read_all_stats members are allowed
		 */
		if (may_read_all_stats || userid == GetUserId())
			values[i++] = UInt32GetDatum(ip);
		else
			nulls[i++] = true;

		/* queryid at column number 6 */
		values[i++] = Int64GetDatum(queryid);

		/* planid at column number 7 */
		if (planid)
			values[i++] = Int64GetDatum(planid);
		else
			nulls[i++] = true;

		if (may_read_all_stats || userid == GetUserId())
		{
			if (showtext)
			{
				/* query at column number 8 */
				values[i++] = CStringGetTextDatum(query_text);
				/* plan at column number 9 */
				if (planid && tmp.planinfo.plan_text[0])
					values[i++] = CStringGetTextDatum(tmp.planinfo.plan_text);
				else
					nulls[i++] = true;
			}
			else
			{
				/* query at column number 8 */
				nulls[i++] = true;
				/* plan at column number 9 */
				nulls[i++] = true;
			}
		}
		else
		{
			/* query text and plan at column number 8 and 9 */
			values[i++] = CStringGetTextDatum("<insufficient privilege>");
			values[i++] = CStringGetTextDatum("<insufficient privilege>");
		}

		/* pgsm_query_id at column number 10 */
		if (pgsm_query_id)
			values[i++] = Int64GetDatum(pgsm_query_id);
		else
			nulls[i++] = true;

		/* parentid at column number 11 */
		if (tmpkey.parentid != INT64CONST(0))
		{
			values[i++] = Int64GetDatum(tmpkey.parentid);
			values[i++] = CStringGetTextDatum(parent_query_text);
		}
		else
		{
			nulls[i++] = true;
			nulls[i++] = true;
		}

		/* application_name at column number 13 */
		if (strlen(tmp.info.application_name) > 0)
			values[i++] = CStringGetTextDatum(tmp.info.application_name);
		else
			nulls[i++] = true;

		/* relations at column number 14 */
		if (tmp.info.num_relations > 0)
		{
			StringInfoData buf;

			initStringInfo(&buf);

			for (int j = 0; j < tmp.info.num_relations; j++)
			{
				if (j > 0)
					appendStringInfoChar(&buf, ',');
				appendStringInfoString(&buf, tmp.info.relations[j]);
			}

			values[i++] = CStringGetTextDatum(buf.data);
			pfree(buf.data);
		}
		else
			nulls[i++] = true;

		/* cmd_type at column number 15 */
		if (tmp.info.cmd_type == CMD_NOTHING)
			nulls[i++] = true;
		else
			values[i++] = Int64GetDatumFast((int64) tmp.info.cmd_type);

		/* elevel at column number 16 */
		values[i++] = Int64GetDatumFast(tmp.error.elevel);

		/* sqlcode at column number 17 */
		if (strlen(tmp.error.sqlcode) == 0)
			nulls[i++] = true;
		else
			values[i++] = CStringGetTextDatum(tmp.error.sqlcode);

		/* message at column number 18 */
		if (strlen(tmp.error.message) == 0)
			nulls[i++] = true;
		else
			values[i++] = CStringGetTextDatum(tmp.error.message);

		/* bucket_start_time at column number 19 */
		values[i++] = TimestampTzGetDatum(pgsm->bucket_start_time[entry->key.bucket_id]);

		if (tmp.calls.calls == 0)
		{
			/* Query of pg_stat_monitor itself started from zero count */
			tmp.calls.calls++;
			tmp.resp_calls[0]++;
		}

		/* calls at column number 20 */
		values[i++] = Int64GetDatumFast(tmp.calls.calls);

		/* total_time at column number 21 */
		values[i++] = Float8GetDatumFast(tmp.time.total_time);

		/* min_time at column number 22 */
		values[i++] = Float8GetDatumFast(tmp.time.min_time);

		/* max_time at column number 23 */
		values[i++] = Float8GetDatumFast(tmp.time.max_time);

		/* mean_time at column number 24 */
		values[i++] = Float8GetDatumFast(tmp.time.mean_time);
		if (tmp.calls.calls > 1)
			stddev = sqrt(tmp.time.sum_var_time / tmp.calls.calls);
		else
			stddev = 0.0;

		/* stddev_exec_time at column number 25 */
		values[i++] = Float8GetDatumFast(stddev);

		/* rows at column number 26 */
		values[i++] = Int64GetDatumFast(tmp.calls.rows);

		if (tmp.calls.calls == 0)
		{
			/* Query of pg_stat_monitor itslef started from zero count */
			tmp.calls.calls++;
			tmp.resp_calls[0]++;
		}

		/* plans at column number 27 */
		values[i++] = Int64GetDatumFast(tmp.plancalls.calls);

		/* total_plan_time at column number 28 */
		values[i++] = Float8GetDatumFast(tmp.plantime.total_time);

		/* min_plan_time at column number 29 */
		values[i++] = Float8GetDatumFast(tmp.plantime.min_time);

		/* max_plan_time at column number 30 */
		values[i++] = Float8GetDatumFast(tmp.plantime.max_time);

		/* mean_plan_time at column number 31 */
		values[i++] = Float8GetDatumFast(tmp.plantime.mean_time);
		if (tmp.plancalls.calls > 1)
			stddev = sqrt(tmp.plantime.sum_var_time / tmp.plancalls.calls);
		else
			stddev = 0.0;

		/* stddev_plan_time at column number 32 */
		values[i++] = Float8GetDatumFast(stddev);

		/* blocks are from column number 33 - 48 */
		values[i++] = Int64GetDatumFast(tmp.blocks.shared_blks_hit);
		values[i++] = Int64GetDatumFast(tmp.blocks.shared_blks_read);
		values[i++] = Int64GetDatumFast(tmp.blocks.shared_blks_dirtied);
		values[i++] = Int64GetDatumFast(tmp.blocks.shared_blks_written);
		values[i++] = Int64GetDatumFast(tmp.blocks.local_blks_hit);
		values[i++] = Int64GetDatumFast(tmp.blocks.local_blks_read);
		values[i++] = Int64GetDatumFast(tmp.blocks.local_blks_dirtied);
		values[i++] = Int64GetDatumFast(tmp.blocks.local_blks_written);
		values[i++] = Int64GetDatumFast(tmp.blocks.temp_blks_read);
		values[i++] = Int64GetDatumFast(tmp.blocks.temp_blks_written);
		values[i++] = Float8GetDatumFast(tmp.blocks.shared_blk_read_time);
		values[i++] = Float8GetDatumFast(tmp.blocks.shared_blk_write_time);
		if (api_version >= PGSM_V2_1)
		{
			values[i++] = Float8GetDatumFast(tmp.blocks.local_blk_read_time);
			values[i++] = Float8GetDatumFast(tmp.blocks.local_blk_write_time);
		}
		values[i++] = Float8GetDatumFast(tmp.blocks.temp_blk_read_time);
		values[i++] = Float8GetDatumFast(tmp.blocks.temp_blk_write_time);

		/* resp_calls at column number 49 */
		values[i++] = intarray_get_datum(tmp.resp_calls, hist_bucket_count_total);

		/* cpu_user_time at column number 50 */
		values[i++] = Float8GetDatumFast(tmp.sysinfo.utime);

		/* cpu_sys_time at column number 51 */
		values[i++] = Float8GetDatumFast(tmp.sysinfo.stime);

		/* wal_records at column number 52 */
		values[i++] = Int64GetDatumFast(tmp.walusage.wal_records);

		/* wal_fpi at column number 53 */
		values[i++] = Int64GetDatumFast(tmp.walusage.wal_fpi);

		{
			char		buf[256];
			Datum		wal_bytes;

			snprintf(buf, sizeof(buf), UINT64_FORMAT, tmp.walusage.wal_bytes);

			/* Convert to numeric */
			wal_bytes = DirectFunctionCall3(numeric_in,
											CStringGetDatum(buf),
											ObjectIdGetDatum(0),
											Int32GetDatum(-1));
			/* wal_bytes at column number 54 */
			values[i++] = wal_bytes;
		}

		if (api_version >= PGSM_V2_3)
		{
			/* wal_buffers_full at column number 55 */
			values[i++] = Int64GetDatumFast(tmp.walusage.wal_buffers_full);
		}

		/* application_name at column number 56 */
		if (strlen(tmp.info.comments) > 0)
			values[i++] = CStringGetTextDatum(tmp.info.comments);
		else
			nulls[i++] = true;

		/* blocks are from column number 57 - 64 */
		values[i++] = Int64GetDatumFast(tmp.jitinfo.jit_functions);
		values[i++] = Float8GetDatumFast(tmp.jitinfo.jit_generation_time);
		values[i++] = Int64GetDatumFast(tmp.jitinfo.jit_inlining_count);
		values[i++] = Float8GetDatumFast(tmp.jitinfo.jit_inlining_time);
		values[i++] = Int64GetDatumFast(tmp.jitinfo.jit_optimization_count);
		values[i++] = Float8GetDatumFast(tmp.jitinfo.jit_optimization_time);
		values[i++] = Int64GetDatumFast(tmp.jitinfo.jit_emission_count);
		values[i++] = Float8GetDatumFast(tmp.jitinfo.jit_emission_time);
		if (api_version >= PGSM_V2_1)
		{
			/* at column number 65 */
			values[i++] = Int64GetDatumFast(tmp.jitinfo.jit_deform_count);
			values[i++] = Float8GetDatumFast(tmp.jitinfo.jit_deform_time);
		}

		if (api_version >= PGSM_V2_3)
		{
			/* at column number 67 */
			values[i++] = Int64GetDatumFast(tmp.parallel_workers_to_launch);
			values[i++] = Int64GetDatumFast(tmp.parallel_workers_launched);
		}

		if (api_version >= PGSM_V2_1)
		{
			/* at column number 69 */
			values[i++] = TimestampTzGetDatum(entry->stats_since);
			values[i++] = TimestampTzGetDatum(entry->minmax_stats_since);
		}

		/* toplevel at column number 71 */
		values[i++] = BoolGetDatum(toplevel);

		/* bucket_done at column number 72 */
		values[i++] = BoolGetDatum(bucketid != current_bucket);

		/* clean up and return the tuplestore */
		tuplestore_putvalues(tupstore, tupdesc, values, nulls);
	}
	/* clean up and return the tuplestore */
	pgsm_lock_release(pgsm);
}

static const char *
decode_error_level(int elevel)
{
	switch (elevel)
	{
		case 0:					/* compatibility with legacy code */
			return "";
		case DEBUG5:
			return "DEBUG5";
		case DEBUG4:
			return "DEBUG4";
		case DEBUG3:
			return "DEBUG3";
		case DEBUG2:
			return "DEBUG2";
		case DEBUG1:
			return "DEBUG1";
		case LOG:
			return "LOG";
		case LOG_SERVER_ONLY:
			return "LOG_SERVER_ONLY";
		case INFO:
			return "INFO";
		case NOTICE:
			return "NOTICE";
		case WARNING:
			return "WARNING";
		case WARNING_CLIENT_ONLY:
			return "WARNING_CLIENT_ONLY";
		case ERROR:
			return "ERROR";
		case FATAL:
			return "FATAL";
		case PANIC:
			return "PANIC";
		default:
			return NULL;
	}
}

Datum
pg_stat_monitor_decode_error_level(PG_FUNCTION_ARGS)
{
	const char *severity = decode_error_level(PG_GETARG_INT32(0));

	if (severity == NULL)
		PG_RETURN_NULL();

	PG_RETURN_TEXT_P(cstring_to_text(severity));
}

static const char *
get_cmd_type(int cmd_type)
{
	switch (cmd_type)
	{
		case CMD_UNKNOWN:
			return "";			/* compatibility with legacy code */
		case CMD_SELECT:
			return "SELECT";
		case CMD_UPDATE:
			return "UPDATE";
		case CMD_INSERT:
			return "INSERT";
		case CMD_DELETE:
			return "DELETE";
#if PG_VERSION_NUM >= 150000
		case CMD_MERGE:
			return "MERGE";
#endif
		case CMD_UTILITY:
			return "UTILITY";
		case CMD_NOTHING:
			return "NOTHING";
		default:
			return NULL;
	}
}

Datum
pg_stat_monitor_get_cmd_type(PG_FUNCTION_ARGS)
{
	const char *cmd_string = get_cmd_type(PG_GETARG_INT32(0));

	if (cmd_string == NULL)
		PG_RETURN_NULL();

	PG_RETURN_TEXT_P(cstring_to_text(cmd_string));
}

static uint64
get_next_wbucket(pgsmSharedState *pgsm)
{
	struct timeval tv;
	uint64		current_bucket_sec;
	bool		update_bucket = false;

	gettimeofday(&tv, NULL);
	current_bucket_sec = pg_atomic_read_u64(&pgsm->prev_bucket_sec);

	/*
	 * If current bucket expired we loop attempting to update prev_bucket_sec.
	 *
	 * pg_atomic_compare_exchange_u64 may fail in two possible ways: 1.
	 * Another thread/process updated the variable before us. 2. A spurious
	 * failure / hardware event.
	 *
	 * In both failure cases we read prev_bucket_sec from memory again, if it
	 * was a spurious failure then the value of prev_bucket_sec must be the
	 * same as before, which will cause the while loop to execute again.
	 *
	 * If another thread updated prev_bucket_sec, then its current value will
	 * definitely make the while condition to fail, we can stop the loop as
	 * another thread has already updated prev_bucket_sec.
	 */
	while ((tv.tv_sec - (uint) current_bucket_sec) >= ((uint) pgsm_bucket_time))
	{
		if (pg_atomic_compare_exchange_u64(&pgsm->prev_bucket_sec, &current_bucket_sec, (uint64) tv.tv_sec))
		{
			update_bucket = true;
			break;
		}

		current_bucket_sec = pg_atomic_read_u64(&pgsm->prev_bucket_sec);
	}

	if (update_bucket)
	{
		uint64		new_bucket_id;

		new_bucket_id = (tv.tv_sec / pgsm_bucket_time) % pgsm_max_buckets;

		/* Update bucket id and retrieve the previous one. */
		pg_atomic_exchange_u64(&pgsm->current_wbucket, new_bucket_id);

		pgsm_lock_aquire(pgsm, LW_EXCLUSIVE);
		hash_entry_dealloc(new_bucket_id);

		pgsm_lock_release(pgsm);

		/* Align the value in prev_bucket_sec to the bucket start time */
		tv.tv_sec = (tv.tv_sec) - (tv.tv_sec % pgsm_bucket_time);

		pg_atomic_exchange_u64(&pgsm->prev_bucket_sec, (uint64) tv.tv_sec);

		pgsm->bucket_start_time[new_bucket_id] = (TimestampTz) tv.tv_sec -
			((POSTGRES_EPOCH_JDATE - UNIX_EPOCH_JDATE) * SECS_PER_DAY);
		pgsm->bucket_start_time[new_bucket_id] = pgsm->bucket_start_time[new_bucket_id] * USECS_PER_SEC;
		return new_bucket_id;
	}

	return pg_atomic_read_u64(&pgsm->current_wbucket);
}

/*
 * This function expects a NORMALIZED query as the input. It iterates over the
 * normalized query skipping comments and multiple spaces. All spaces are
 * converted to ' ' so that we the calculation is independent of the space
 * type whether newline, tab, or any other type. Trailing and leading spaces
 * are also removed before calculating the hash.
 */
static int64
get_pgsm_query_id_hash(const char *norm_query, int norm_len)
{
	char	   *query;
	char	   *q_iter;
	const char *norm_q_iter = norm_query;
	bool		space = false;
	int64		pgsm_query_id;

	Assert(norm_query != NULL);

	if (!pgsm_enable_pgsm_query_id)
		return 0;

	query = palloc(norm_len + 1);
	q_iter = query;

	while (*norm_q_iter && norm_q_iter < norm_query + norm_len)
	{
		if (*norm_q_iter == '/' && *(norm_q_iter + 1) == '*')
		{
			/* Skip multiline comments */
			norm_q_iter++;
			norm_q_iter++;

			while (*norm_q_iter)
			{
				if (*norm_q_iter == '*' && *(norm_q_iter + 1) == '/')
				{
					norm_q_iter++;
					norm_q_iter++;
					break;
				}

				norm_q_iter++;
			}
		}
		else if (*norm_q_iter == '-' && *(norm_q_iter + 1) == '-')
		{
			/* Skip single line comments */
			norm_q_iter++;
			norm_q_iter++;

			while (*norm_q_iter && *norm_q_iter != '\n')
				norm_q_iter++;
		}
		else if (scanner_isspace(*norm_q_iter))
		{
			/* Convert white spaces into single space */
			norm_q_iter++;

			space = true;
		}
		else
		{
			/* Output a single space unless at start of query */
			if (space && q_iter != query)
				*q_iter++ = ' ';

			space = false;

			*q_iter++ = *norm_q_iter++;
		}
	}

	*q_iter = '\0';

	pgsm_query_id = pgsm_hash_string(query, q_iter - query);

	pfree(query);

	return pgsm_query_id;
}

/*
 * Generate a normalized version of the query string that will be used to
 * represent all similar queries.
 *
 * Note that the normalized representation may well vary depending on
 * just which "equivalent" query is used to create the hashtable entry.
 * We assume this is OK.
 *
 * If query_loc > 0, then "query" has been advanced by that much compared to
 * the original string start, so we need to translate the provided locations
 * to compensate.  (This lets us avoid re-scanning statements before the one
 * of interest, so it's worth doing.)
 *
 * *query_len_p contains the input string length, and is updated with
 * the result string length on exit.  The resulting string might be longer
 * or shorter depending on what happens with replacement of constants.
 *
 * Returns a palloc'd string.
 */
static char *
generate_normalized_query(JumbleState *jstate, const char *query,
						  int query_loc, int *query_len_p)
{
	char	   *norm_query;
	int			query_len = *query_len_p;
	int			norm_query_buflen,	/* Space allowed for norm_query */
				len_to_wrt,		/* Length (in bytes) to write */
				quer_loc = 0,	/* Source query byte location */
				n_quer_loc = 0, /* Normalized query byte location */
				last_off = 0,	/* Offset from start for previous tok */
				last_tok_len = 0;	/* Length (in bytes) of that tok */
#if PG_VERSION_NUM >= 180000
	int			num_constants_replaced = 0;
#endif

	/*
	 * Get constants' lengths (core system only gives us locations).  Note
	 * this also ensures the items are sorted by location.
	 */
	fill_in_constant_lengths(jstate, query, query_loc);

	/*
	 * Allow for $n symbols to be longer than the constants they replace.
	 * Constants must take at least one byte in text form, while a $n symbol
	 * certainly isn't more than 11 bytes, even if n reaches INT_MAX.  We
	 * could refine that limit based on the max value of n for the current
	 * query, but it hardly seems worth any extra effort to do so.
	 */
	norm_query_buflen = query_len + jstate->clocations_count * 10;

	/* Allocate result buffer */
	norm_query = palloc(norm_query_buflen + 1);

	for (int i = 0; i < jstate->clocations_count; i++)
	{
		int			off,		/* Offset from start for cur tok */
					tok_len;	/* Length (in bytes) of that tok */

#if PG_VERSION_NUM >= 180000

		/*
		 * If we have an external param at this location, but no lists are
		 * being squashed across the query, then we skip here; this will make
		 * us print the characters found in the original query that represent
		 * the parameter in the next iteration (or after the loop is done),
		 * which is a bit odd but seems to work okay in most cases.
		 */
		if (jstate->clocations[i].extern_param && !jstate->has_squashed_lists)
			continue;
#endif

		off = jstate->clocations[i].location;
		/* Adjust recorded location if we're dealing with partial string */
		off -= query_loc;

		tok_len = jstate->clocations[i].length;

		if (tok_len < 0)
			continue;			/* ignore any duplicates */

		/* Copy next chunk (what precedes the next constant) */
		len_to_wrt = off - last_off;
		len_to_wrt -= last_tok_len;

		Assert(len_to_wrt >= 0);
		memcpy(norm_query + n_quer_loc, query + quer_loc, len_to_wrt);
		n_quer_loc += len_to_wrt;

#if PG_VERSION_NUM >= 180000

		/*
		 * And insert a param symbol in place of the constant token; and, if
		 * we have a squashable list, insert a placeholder comment starting
		 * from the list's second value.
		 */
		n_quer_loc += sprintf(norm_query + n_quer_loc, "$%d%s",
							  num_constants_replaced + 1 + jstate->highest_extern_param_id,
							  jstate->clocations[i].squashed ? " /*, ... */" : "");
		num_constants_replaced++;
#else
		/* And insert a param symbol in place of the constant token */
		n_quer_loc += sprintf(norm_query + n_quer_loc, "$%d",
							  i + 1 + jstate->highest_extern_param_id);
#endif

		/* move forward */
		quer_loc = off + tok_len;
		last_off = off;
		last_tok_len = tok_len;
	}

	/*
	 * We've copied up until the last ignorable constant.  Copy over the
	 * remaining bytes of the original query string.
	 */
	len_to_wrt = query_len - quer_loc;

	Assert(len_to_wrt >= 0);
	memcpy(norm_query + n_quer_loc, query + quer_loc, len_to_wrt);
	n_quer_loc += len_to_wrt;

	Assert(n_quer_loc <= norm_query_buflen);
	norm_query[n_quer_loc] = '\0';

	*query_len_p = n_quer_loc;
	return norm_query;
}

/*
 * Given a valid SQL string and an array of constant-location records,
 * fill in the textual lengths of those constants.
 *
 * The constants may use any allowed constant syntax, such as float literals,
 * bit-strings, single-quoted strings and dollar-quoted strings.  This is
 * accomplished by using the public API for the core scanner.
 *
 * It is the caller's job to ensure that the string is a valid SQL statement
 * with constants at the indicated locations.  Since in practice the string
 * has already been parsed, and the locations that the caller provides will
 * have originated from within the authoritative parser, this should not be
 * a problem.
 *
 * Duplicate constant pointers are possible, and will have their lengths
 * marked as '-1', so that they are later ignored.  (Actually, we assume the
 * lengths were initialized as -1 to start with, and don't change them here.)
 *
 * If query_loc > 0, then "query" has been advanced by that much compared to
 * the original string start, so we need to translate the provided locations
 * to compensate.  (This lets us avoid re-scanning statements before the one
 * of interest, so it's worth doing.)
 *
 * N.B. There is an assumption that a '-' character at a Const location begins
 * a negative numeric constant.  This precludes there ever being another
 * reason for a constant to start with a '-'.
 */
static void
fill_in_constant_lengths(JumbleState *jstate, const char *query,
						 int query_loc)
{
	LocationLen *locs;
	core_yyscan_t yyscanner;
	core_yy_extra_type yyextra;
	core_YYSTYPE yylval;
	YYLTYPE		yylloc;
	int			last_loc = -1;
	int			i;

	/*
	 * Sort the records by location so that we can process them in order while
	 * scanning the query text.
	 */
	if (jstate->clocations_count > 1)
		qsort(jstate->clocations, jstate->clocations_count,
			  sizeof(LocationLen), comp_location);
	locs = jstate->clocations;

	/* initialize the flex scanner --- should match raw_parser() */
	yyscanner = scanner_init(query,
							 &yyextra,
							 &ScanKeywords,
							 ScanKeywordTokens);

	/* we don't want to re-emit any escape string warnings */
	yyextra.escape_string_warning = false;

	/* Search for each constant, in sequence */
	for (i = 0; i < jstate->clocations_count; i++)
	{
		int			loc = locs[i].location;
		int			tok;

		/* Adjust recorded location if we're dealing with partial string */
		loc -= query_loc;

		Assert(loc >= 0);

#if PG_VERSION_NUM >= 180000
		if (locs[i].squashed)
			continue;			/* squashable list, ignore */
#endif

		if (loc <= last_loc)
			continue;			/* Duplicate constant, ignore */

		/* Lex tokens until we find the desired constant */
		for (;;)
		{
			tok = core_yylex(&yylval, &yylloc, yyscanner);

			/* We should not hit end-of-string, but if we do, behave sanely */
			if (tok == 0)
				break;			/* out of inner for-loop */

			/*
			 * We should find the token position exactly, but if we somehow
			 * run past it, work with that.
			 */
			if (yylloc >= loc)
			{
				if (query[loc] == '-')
				{
					/*
					 * It's a negative value - this is the one and only case
					 * where we replace more than a single token.
					 *
					 * Do not compensate for the core system's special-case
					 * adjustment of location to that of the leading '-'
					 * operator in the event of a negative constant.  It is
					 * also useful for our purposes to start from the minus
					 * symbol.  In this way, queries like "select * from foo
					 * where bar = 1" and "select * from foo where bar = -2"
					 * will have identical normalized query strings.
					 */
					tok = core_yylex(&yylval, &yylloc, yyscanner);
					if (tok == 0)
						break;	/* out of inner for-loop */
				}

				/*
				 * We now rely on the assumption that flex has placed a zero
				 * byte after the text of the current token in scanbuf.
				 */
				locs[i].length = strlen(yyextra.scanbuf + loc);
				break;			/* out of inner for-loop */
			}
		}

		/* If we hit end-of-string, give up, leaving remaining lengths -1 */
		if (tok == 0)
			break;

		last_loc = loc;
	}

	scanner_finish(yyscanner);
}

/*
 * comp_location: comparator for qsorting LocationLen structs by location
 */
static int
comp_location(const void *a, const void *b)
{
	int			l = ((const LocationLen *) a)->location;
	int			r = ((const LocationLen *) b)->location;

	if (l < r)
		return -1;
	else if (l > r)
		return +1;
	else
		return 0;
}

/* Convert array of integers into Text datum */
static Datum
intarray_get_datum(const int32 *arr, int len)
{
	StringInfoData str;
	Datum		datum;

	if (len < 1)
		return CStringGetTextDatum("");

	initStringInfo(&str);
	appendStringInfo(&str, "%d", arr[0]);

	for (int i = 1; i < len; i++)
		appendStringInfo(&str, ",%d", arr[i]);

	datum = CStringGetTextDatum(str.data);
	pfree(str.data);

	return datum;
}

Datum
pg_stat_monitor_hook_stats(PG_FUNCTION_ARGS)
{
	return (Datum) 0;
}

static void
pgsm_emit_log_hook(ErrorData *edata)
{
	if (!IsSystemInitialized() || edata == NULL)
		goto exit;

	if (IsParallelWorker())
		goto exit;

	/* Check if PostgreSQL has finished its own bootstrapping code. */
	if (MyProc == NULL)
		goto exit;

	if (edata->elevel >= WARNING && debug_query_string && !disable_error_capture && !IsSystemOOM())
		pgsm_store_error(debug_query_string, edata);

	/* We need to make sure we re-enable error capture if query was aborted */
	if (edata->elevel >= ERROR)
		disable_error_capture = false;
exit:
	if (prev_emit_log_hook)
		prev_emit_log_hook(edata);
}

static bool
IsSystemInitialized(void)
{
	return system_init;
}

/*
 * Calculate the time difference in milliseconds.
 */
static double
time_diff(struct timeval end, struct timeval start)
{
	return (end.tv_sec - start.tv_sec) * 1000.0 + (end.tv_usec - start.tv_usec) / 1000.0;
}

/* Validate histogram values and find the max number of histogram buckets that can be created */
static void
set_histogram_bucket_timings(void)
{
	hist_bucket_min = pgsm_histogram_min;
	hist_bucket_max = pgsm_histogram_max;
	hist_bucket_count_user = pgsm_histogram_buckets;

	if (pgsm_histogram_buckets >= 2)
	{
		int			b_count = hist_bucket_count_user;

		for (; hist_bucket_count_user > 0; hist_bucket_count_user--)
		{
			double		b2_start;
			double		b2_end;

			histogram_bucket_timings(2, &b2_start, &b2_end);

			/*
			 * The first bucket size will always be one or greater as we're
			 * doing min value + e^0; and e^0 = 1. Checking if histograms
			 * buckets overlap. That can only happen if the second bucket size
			 * is zero as we using exponential bucket sizes. Therefore, if the
			 * second bucket size is greater than 1, we'll never have
			 * overlapping buckets.
			 */
			if (b2_start != b2_end)
			{
				break;
			}
		}

		if (b_count != hist_bucket_count_user)
			ereport(WARNING,
					errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					errmsg("pg_stat_monitor: Histogram buckets are overlapping."),
					errdetail("Histogram bucket size is set to %d [not including outlier buckets].", hist_bucket_count_user));
	}

	/*
	 * Important that we keep user bucket count separate for calculations, but
	 * must add 1 for max outlier queries. However, for min, bucket should
	 * only be added if the minimum value provided by user is greater than 0
	 */
	hist_bucket_count_total = hist_bucket_count_user + (int) (hist_bucket_max < HISTOGRAM_MAX_TIME) + (int) (hist_bucket_min > 0);

	for (int index = 0; index < hist_bucket_count_total; index++)
	{
		histogram_bucket_timings(index, &hist_bucket_timings[index].start, &hist_bucket_timings[index].end);
	}
}

/*
 * Given an index, return the histogram start and end times.
 */
static void
histogram_bucket_timings(int index, double *b_start, double *b_end)
{
	double		q_min = hist_bucket_min;
	double		q_max = hist_bucket_max;
	int			b_count = hist_bucket_count_total;
	int			b_count_user = hist_bucket_count_user;
	double		bucket_size;

	/*
	 * We must not skip any queries that fall outside the user defined
	 * histogram buckets. So capturing min/max outliers.
	 */
	if (index == 0 && q_min > 0)
	{
		*b_start = 0;
		*b_end = q_min;
		return;
	}
	else if (index == b_count - 1 && q_max < HISTOGRAM_MAX_TIME)
	{
		*b_start = q_max;
		*b_end = INFINITY;
		return;
	}

	/*
	 * Equisized logarithmic values will yield exponential values as required.
	 * For calculating logarithmic value, we MUST use the number of bucket
	 * provided by the user.
	 */
	bucket_size = log(q_max - q_min) / (double) b_count_user;

	/*
	 * Can't do exp(0) as that returns 1. So handling the case of first entry
	 * specifically
	 */
	*b_start = q_min + ((index == 0 || (index == 1 && q_min > 0)) ? 0 : exp(bucket_size * (index - 1 + (q_min == 0))));
	*b_end = q_min + exp(bucket_size * (index + (q_min == 0)));
}

/*
 * Get the histogram bucket index for a given query time.
 */
static int
get_histogram_bucket(double q_time)
{
	for (int index = 0; index < hist_bucket_count_total - 1; index++)
	{
		if (q_time >= hist_bucket_timings[index].start && q_time <= hist_bucket_timings[index].end)
			return index;
	}

	/* Given the uppermost bound is inifity we should never reach this */
	return hist_bucket_count_total - 1;
}

/*
 * Get the timings of the histogram as a single string. The last bucket
 * has ellipses as the end value indication infinity.
 */
Datum
get_histogram_timings(PG_FUNCTION_ARGS)
{
	StringInfoData buf;

	initStringInfo(&buf);

	appendStringInfoChar(&buf, '{');

	for (int index = 0; index < hist_bucket_count_total; index++)
	{
		if (index == 0)
			appendStringInfoChar(&buf, '{');
		else
			appendStringInfoString(&buf, ", (");

		appendStringInfo(&buf, "%.3f - ", hist_bucket_timings[index].start);

		if (hist_bucket_timings[index].end == INFINITY)
			appendStringInfoString(&buf, "...");
		else
			appendStringInfo(&buf, "%.3f", hist_bucket_timings[index].end);

		appendStringInfoChar(&buf, '}');
	}

	appendStringInfoChar(&buf, '}');

	return CStringGetTextDatum(buf.data);
}

static bool
append_comment_char(char *comments, size_t buf_len, size_t *idx, char c)
{
	if (*idx >= buf_len - 1)
		return false;

	comments[(*idx)++] = c;

	return true;
}

static void
extract_query_comments(const char *query, char *comments, size_t buf_len)
{
	size_t		curr_len = 0;

	Assert(query != NULL);

	for (const char *q_iter = query; *q_iter;)
	{
		if (*q_iter == '/' && *(q_iter + 1) == '*')
		{
			/* Add separator between comments */
			if (curr_len > 0)
			{
				if (!append_comment_char(comments, buf_len, &curr_len, ','))
					goto terminate;
				if (!append_comment_char(comments, buf_len, &curr_len, ' '))
					goto terminate;
			}

			if (!append_comment_char(comments, buf_len, &curr_len, *(q_iter++)))
				goto terminate;
			if (!append_comment_char(comments, buf_len, &curr_len, *(q_iter++)))
				goto terminate;

			while (*q_iter)
			{
				if (*q_iter == '*' && *(q_iter + 1) == '/')
				{
					if (!append_comment_char(comments, buf_len, &curr_len, *(q_iter++)))
						goto terminate;
					if (!append_comment_char(comments, buf_len, &curr_len, *(q_iter++)))
						goto terminate;
					break;
				}

				if (!append_comment_char(comments, buf_len, &curr_len, *(q_iter++)))
					goto terminate;
			}
		}
		else
		{
			q_iter++;
		}
	}

terminate:
	comments[curr_len] = '\0';
}

static void
pgsm_lock_aquire(pgsmSharedState *pgsm, LWLockMode mode)
{
	/* Disable error capturing while holding the lock to avoid deadlocks */
	LWLockAcquire(pgsm->lock, mode);
	disable_error_capture = true;
}

static void
pgsm_lock_release(pgsmSharedState *pgsm)
{
	disable_error_capture = false;
	LWLockRelease(pgsm->lock);
}
