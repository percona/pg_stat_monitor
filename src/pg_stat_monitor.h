/*-------------------------------------------------------------------------
 *
 * pg_stat_monitor.h
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

#ifndef __PG_STAT_MONITOR_H__
#define __PG_STAT_MONITOR_H__

#include <postgres.h>

/* XXX: Should USAGE_EXEC reflect execution time and/or buffer usage? */
#define USAGE_EXEC(duration)	(1.0)
#define USAGE_INIT				(1.0)	/* including initial planning */

#define INVALID_BUCKET_ID	-1

typedef enum pgsmStoreKind
{
	PGSM_INVALID = -1,

	/*
	 * PGSM_PLAN and PGSM_EXEC must be respectively 0 and 1 as they're used to
	 * reference the underlying values in the arrays in the Counters struct,
	 * and this order is required in pg_stat_monitor_internal().
	 */
	PGSM_PARSE = 0,
	PGSM_PLAN,
	PGSM_EXEC,
	PGSM_STORE,
	PGSM_ERROR,
} pgsmStoreKind;

#endif							/* __PG_STAT_MONITOR_H__ */
