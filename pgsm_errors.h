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

typedef struct {
    char   message[ERROR_MSG_MAX_LEN];  /* message is also the hash key (MUST BE FIRST). */
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
 * Add an error message to the hash table.
 * Increment no. of calls if message already exists.
 */
void pgsm_log_error(const char *format, ...);

#endif /* PGSM_ERRORS_H */