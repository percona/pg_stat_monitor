/*-------------------------------------------------------------------------
 *
 * pgsm_errors.h
 *		Track pg_stat_monitor internal error messages.
 *
 * Copyright © 2021, Percona LLC and/or its affiliates
 *
 * Portions Copyright (c) 1996-2020, PostgreSQL Global Development Group
 *
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 * IDENTIFICATION
 *	  contrib/pg_stat_monitor/pgsm_errors.h
 *
 *-------------------------------------------------------------------------
 */

#ifndef PGSM_ERRORS_H
#define PGSM_ERRORS_H

#include <stddef.h>

#include <postgres.h>


/* Maximum allowed error message length. */
#define ERROR_MSG_MAX_LEN 128

/* Log message severity. */
typedef enum {
    PSGM_LOG_INFO,
    PGSM_LOG_WARNING,
    PGSM_LOG_ERROR
} PgsmLogSeverity;

typedef struct {
    char   message[ERROR_MSG_MAX_LEN];  /* message is also the hash key (MUST BE FIRST). */
    PgsmLogSeverity severity;
    char   time[60];  /* last timestamp in which this error was reported. */
    int64  calls;     /* how many times this error was reported. */
} ErrorEntry;

/*
 * Must be called during module startup, creates the hash table
 * used to store pg_stat_monitor error messages.
 */
void psgm_errors_init(void);

/*
 * Returns an estimate of the hash table size.
 * Used to reserve space on Postmaster's shared memory.
 */
size_t pgsm_errors_size(void);

/*
 * Add a message to the hash table.
 * Increment no. of calls if message already exists.
 */
void pgsm_log(PgsmLogSeverity severity, const char *format, ...);

#define pgsm_log_info(msg, ...) pgsm_log(PGSM_LOG_INFO, msg, ##__VA_ARGS__)
#define pgsm_log_warning(msg, ...) pgsm_log(PGSM_LOG_WARNING, msg, ##__VA_ARGS__)
#define pgsm_log_error(msg, ...) pgsm_log(PGSM_LOG_ERROR, msg, ##__VA_ARGS__)

#endif /* PGSM_ERRORS_H */