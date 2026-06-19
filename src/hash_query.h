/*-------------------------------------------------------------------------
 *
 * hash_query.h
 *	  Shared memory data structures and hash table interface for
 *	  pg_stat_monitor
 *
 * Portions Copyright © 2018-2025, Percona LLC and/or its affiliates
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */

#ifndef __PGSM_HASH_QUERY_H__
#define __PGSM_HASH_QUERY_H__

#include <postgres.h>

#include <executor/instrument.h>
#include <nodes/nodes.h>
#include <storage/lwlock.h>
#include <storage/spin.h>
#include <utils/dsa.h>
#include <utils/hsearch.h>
#include <utils/timestamp.h>

#include "guc.h"

#define ERROR_MESSAGE_LEN	100
#define REL_LST				10
/* schema + dot + relname + view indication + string terminator */
#define REL_LEN				(NAMEDATALEN + 1 + NAMEDATALEN + 1 + 1)
#define APPLICATIONNAME_LEN	NAMEDATALEN
#define COMMENTS_LEN		256
#define PLAN_TEXT_LEN		1024

#define MAX_QUERY_BUF						((int64) pgsm_query_shared_buffer * 1024 * 1024)
#define MAX_BUCKETS_MEM 					((int64) pgsm_max * 1024 * 1024)
#define MAX_BUCKET_ENTRIES 					(MAX_BUCKETS_MEM / sizeof(pgsmEntry))
#define SQLCODE_LEN							20
#define TOTAL_RELS_LENGTH					(REL_LST * REL_LEN)

#define INVALID_BUCKET_ID	-1

/* shared memory storage for the query */
typedef struct CallTime
{
	double		total_time;		/* total execution time, in msec */
	double		min_time;		/* minimum execution time in msec */
	double		max_time;		/* maximum execution time in msec */
	double		mean_time;		/* mean execution time in msec */
	double		sum_var_time;	/* sum of variances in execution time in msec */
} CallTime;

typedef struct PlanInfo
{
	int64		planid;			/* plan identifier */
	char		plan_text[PLAN_TEXT_LEN];	/* plan text */
	size_t		plan_len;		/* strlen(plan_text) */
} PlanInfo;

typedef struct pgsmHashKey
{
	uint64		bucket_id;		/* bucket number */
	int64		queryid;		/* query identifier */
	int64		planid;			/* plan identifier */
	int64		appid;			/* hash of application name */
	Oid			userid;			/* user OID */
	Oid			dbid;			/* database OID */
	uint32		ip;				/* client ip address */
	bool		toplevel;		/* query executed at top level */
	int64		parentid;		/* parent queryId of current query */
} pgsmHashKey;

typedef struct QueryInfo
{
	dsa_pointer parent_query;
	int64		type;			/* type of query, options are query, info,
								 * warning, error, fatal */
	char		application_name[APPLICATIONNAME_LEN];
	char		comments[COMMENTS_LEN];
	char		relations[REL_LST][REL_LEN];	/* List of relation involved
												 * in the query */
	int			num_relations;	/* Number of relation in the query */
	CmdType		cmd_type;		/* query command type
								 * SELECT/UPDATE/DELETE/INSERT */
} QueryInfo;

typedef struct ErrorInfo
{
	int64		elevel;			/* error elevel */
	char		sqlcode[SQLCODE_LEN];	/* error sqlcode  */
	char		message[ERROR_MESSAGE_LEN]; /* error message text */
} ErrorInfo;

typedef struct Calls
{
	int64		calls;			/* # of times executed */
	int64		rows;			/* total # of retrieved or affected rows */
} Calls;

typedef struct Blocks
{
	int64		shared_blks_hit;	/* # of shared buffer hits */
	int64		shared_blks_read;	/* # of shared disk blocks read */
	int64		shared_blks_dirtied;	/* # of shared disk blocks dirtied */
	int64		shared_blks_written;	/* # of shared disk blocks written */
	int64		local_blks_hit; /* # of local buffer hits */
	int64		local_blks_read;	/* # of local disk blocks read */
	int64		local_blks_dirtied; /* # of local disk blocks dirtied */
	int64		local_blks_written; /* # of local disk blocks written */
	int64		temp_blks_read; /* # of temp blocks read */
	int64		temp_blks_written;	/* # of temp blocks written */
	double		shared_blk_read_time;	/* time spent reading shared blocks,
										 * in msec */
	double		shared_blk_write_time;	/* time spent writing shared blocks,
										 * in msec */
	double		local_blk_read_time;	/* time spent reading local blocks, in
										 * msec */
	double		local_blk_write_time;	/* time spent writing local blocks, in
										 * msec */
	double		temp_blk_read_time; /* time spent reading temp blocks, in msec */
	double		temp_blk_write_time;	/* time spent writing temp blocks, in
										 * msec */

	/*
	 * Variables for local entry. The values to be passed to pgsm_update_entry
	 * from pgsm_store.
	 */
	instr_time	instr_shared_blk_read_time; /* time spent reading shared
											 * blocks */
	instr_time	instr_shared_blk_write_time;	/* time spent writing shared
												 * blocks */
	instr_time	instr_local_blk_read_time;	/* time spent reading local blocks */
	instr_time	instr_local_blk_write_time; /* time spent writing local blocks */
	instr_time	instr_temp_blk_read_time;	/* time spent reading temp blocks */
	instr_time	instr_temp_blk_write_time;	/* time spent writing temp blocks */
} Blocks;

typedef struct JitInfo
{
	int64		jit_functions;	/* total number of JIT functions emitted */
	double		jit_generation_time;	/* total time to generate jit code */
	int64		jit_inlining_count; /* number of times inlining time has been
									 * > 0 */
	double		jit_deform_time;	/* total time to deform tuples in jit code */
	int64		jit_deform_count;	/* number of times deform time has been >
									 * 0 */
	double		jit_inlining_time;	/* total time to inline jit code */
	int64		jit_optimization_count; /* number of times optimization time
										 * has been > 0 */
	double		jit_optimization_time;	/* total time to optimize jit code */
	int64		jit_emission_count; /* number of times emission time has been
									 * > 0 */
	double		jit_emission_time;	/* total time to emit jit code */

	/*
	 * Variables for local entry. The values to be passed to pgsm_update_entry
	 * from pgsm_store.
	 */
	instr_time	instr_generation_counter;	/* generation counter */
	instr_time	instr_inlining_counter; /* inlining counter */
	instr_time	instr_deform_counter;	/* deform counter */
	instr_time	instr_optimization_counter; /* optimization counter */
	instr_time	instr_emission_counter; /* emission counter */
} JitInfo;

typedef struct SysInfo
{
	double		utime;			/* user cpu time */
	double		stime;			/* system cpu time */
} SysInfo;

typedef struct Wal_Usage
{
	int64		wal_records;	/* # of WAL records generated */
	int64		wal_fpi;		/* # of WAL full page images generated */
	uint64		wal_bytes;		/* total amount of WAL bytes generated */
	int64		wal_buffers_full;	/* # of times the WAL buffers became full */
} Wal_Usage;

typedef struct Counters
{
	Calls		calls;
	QueryInfo	info;
	CallTime	time;

	Calls		plancalls;
	CallTime	plantime;
	PlanInfo	planinfo;

	Blocks		blocks;
	SysInfo		sysinfo;
	JitInfo		jitinfo;
	ErrorInfo	error;
	Wal_Usage	walusage;
	int			resp_calls[MAX_RESPONSE_BUCKET + 2];	/* execution time's in
														 * msec; including 2
														 * outlier buckets */
	int64		parallel_workers_to_launch; /* # of parallel workers planned
											 * to be launched */
	int64		parallel_workers_launched;	/* # of parallel workers actually
											 * launched */
} Counters;

/*
 * Statistics per statement
 */
typedef struct pgsmEntry
{
	pgsmHashKey key;			/* hash key of entry - MUST BE FIRST */
	int64		pgsm_query_id;	/* pgsm generate normalized query hash */
	char		datname[NAMEDATALEN];	/* database name */
	char		username[NAMEDATALEN];	/* user name */
	Counters	counters;		/* the statistics for this query */
	TimestampTz stats_since;	/* timestamp of entry allocation */
	TimestampTz minmax_stats_since; /* timestamp of last min/max values reset */
	slock_t		mutex;			/* protects the counters only */
	union
	{
		dsa_pointer query_pos;	/* query location within query buffer */
		char	   *query_pointer;
	}			query_text;
} pgsmEntry;

/*
 * Global shared state
 */
typedef struct pgsmSharedState
{
	LWLock	   *lock;			/* protects hashtable search/modification */
	pg_atomic_uint64 current_wbucket;
	pg_atomic_uint64 prev_bucket_sec;
	void	   *raw_dsa_area;	/* DSA area pointer to store query texts */
	HTAB	   *hash_handle;

	bool		pgsm_oom;
	TimestampTz bucket_start_time[];	/* start time of the bucket */
} pgsmSharedState;

/* hash_query.c */
void		pgsm_startup(void);
MemoryContext GetPgsmMemoryContext(void);
dsa_area   *get_dsa_area_for_query_text(void);
HTAB	   *get_pgsmHash(void);
bool		IsSystemOOM(void);
Size		pgsm_ShmemSize(void);
pgsmSharedState *pgsm_get_ss(void);
void		hash_entry_dealloc(int new_bucket_id, int old_bucket_id);
pgsmEntry  *hash_entry_alloc(pgsmSharedState *pgsm, const pgsmHashKey *key);

#endif							/* __PGSM_HASH_QUERY_H__ */
