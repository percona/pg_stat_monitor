/*-------------------------------------------------------------------------
 *
 * guc.h
 *	  GUC variable declarations for pg_stat_monitor
 *
 * Portions Copyright © 2018-2025, Percona LLC and/or its affiliates
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 *
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 *-------------------------------------------------------------------------
 */
#ifndef __PGSM_GUC_H__
#define __PGSM_GUC_H__

#include <postgres.h>

#include <utils/guc.h>

#define HISTOGRAM_MAX_TIME		50000000
#define MAX_RESPONSE_BUCKET		50

typedef enum
{
	PSGM_TRACK_NONE = 0,		/* track no statements */
	PGSM_TRACK_TOP,				/* only top level statements */
	PGSM_TRACK_ALL				/* all statements, including nested ones */
}			PGSMTrackLevel;

extern int	pgsm_max;
extern int	pgsm_query_max_len;
extern int	pgsm_bucket_time;
extern int	pgsm_max_buckets;
extern int	pgsm_histogram_buckets;
extern double pgsm_histogram_min;
extern double pgsm_histogram_max;
extern int	pgsm_query_shared_buffer;
extern bool pgsm_track_planning;
extern bool pgsm_extract_comments;
extern bool pgsm_enable_query_plan;
extern bool pgsm_enable_overflow;
extern bool pgsm_normalized_query;
extern bool pgsm_track_utility;
extern bool pgsm_track_application_names;
extern bool pgsm_enable_pgsm_query_id;
extern int	pgsm_track;

void		init_guc(void);

#endif							/* __PGSM_GUC_H__ */
