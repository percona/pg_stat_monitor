/*-------------------------------------------------------------------------
 *
 * hash_query.c
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

#include <storage/ipc.h>
#include <storage/shmem.h>
#include <utils/memutils.h>

#include "hash_query.h"

typedef struct pgsmLocalState
{
	pgsmSharedState *shared_pgsmState;
	dsa_area   *dsa;			/* local dsa area for backend attached to the
								 * dsa area created by postmaster at startup. */
	HTAB	   *shared_hash;
} pgsmLocalState;

static pgsmLocalState pgsmStateLocal;

static void pgsm_attach_shmem(void);
static HTAB *pgsm_create_bucket_hash(void);
static Size pgsm_get_shared_area_size(void);

#define PGSM_BUCKET_INFO_SIZE	(sizeof(TimestampTz) * pgsm_max_buckets)
#define PGSM_SHARED_STATE_SIZE	(sizeof(pgsmSharedState) + PGSM_BUCKET_INFO_SIZE)

/*
 * Returns the shared memory area size for storing the query texts
 */
static Size
pgsm_query_area_size(void)
{
	return MAXALIGN(MAX_QUERY_BUF);
}

/*
 * Total shared memory area required by pgsm
 */
Size
pgsm_ShmemSize(void)
{
	Size		sz = MAXALIGN(PGSM_SHARED_STATE_SIZE);

	sz = add_size(sz, MAX_QUERY_BUF);
	sz = add_size(sz, hash_estimate_size(MAX_BUCKET_ENTRIES, sizeof(pgsmEntry)));
	return MAXALIGN(sz);
}

/*
 * Returns the shared memory area size for storing the query texts and pgsm
 * shared state structure
 */
static Size
pgsm_get_shared_area_size(void)
{
	Size		sz = MAXALIGN(PGSM_SHARED_STATE_SIZE);

	sz = add_size(sz, pgsm_query_area_size());
	return sz;
}

void
pgsm_startup(void)
{
	bool		found;
	pgsmSharedState *pgsm;

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	pgsm = ShmemInitStruct("pg_stat_monitor", pgsm_get_shared_area_size(), &found);
	if (!found)
	{
		/* First time through ... */
		dsa_area   *dsa;
		char	   *p = (char *) pgsm;

		/* Initialize fields */
		pgsm->pgsm_oom = false;
		pgsm->lock = &GetNamedLWLockTranche("pg_stat_monitor")->lock;
		pg_atomic_init_u64(&pgsm->current_wbucket, 0);
		pg_atomic_init_u64(&pgsm->prev_bucket_sec, 0);

		/* the allocation of pgsmSharedState itself */
		p += MAXALIGN(PGSM_SHARED_STATE_SIZE);
		pgsm->raw_dsa_area = p;
		dsa = dsa_create_in_place(pgsm->raw_dsa_area,
								  pgsm_query_area_size(),
								  LWLockNewTrancheId(), 0);
		dsa_pin(dsa);
		dsa_set_size_limit(dsa, pgsm_query_area_size());

		pgsm->hash_handle = pgsm_create_bucket_hash();

		/*
		 * If overflow is enabled, set the DSA size to unlimited, and allow
		 * the DSA to grow beyond the shared memory space into the swap area
		 */
		if (pgsm_enable_overflow)
			dsa_set_size_limit(dsa, -1);

		/*
		 * Postmaster will never access the dsa again, thus free its local
		 * references.
		 */
		dsa_detach(dsa);
	}

	LWLockRelease(AddinShmemInitLock);

	pgsmStateLocal.shared_pgsmState = pgsm;

	/* Reset in case this is a restart within the postmaster */
	pgsmStateLocal.dsa = NULL;
	pgsmStateLocal.shared_hash = NULL;
}

/*
 * Create hash table for storing the query statistics.
 */
static HTAB *
pgsm_create_bucket_hash(void)
{
	HASHCTL		info = {
		.keysize = sizeof(pgsmHashKey),
		.entrysize = sizeof(pgsmEntry),
	};

	return ShmemInitHash("pg_stat_monitor: bucket hashtable", MAX_BUCKET_ENTRIES, MAX_BUCKET_ENTRIES, &info, HASH_ELEM | HASH_BLOBS);
}

/*
 * Attach to the DSA area created by the postmaster.
 *
 * Note: The dsa area for the process may be mapped at a different virtual
 * address in this process.
 */
static void
pgsm_attach_shmem(void)
{
	MemoryContext oldcontext;

	if (pgsmStateLocal.dsa)
		return;

	/*
	 * We want the dsa to remain valid throughout the lifecycle of this
	 * process. so switch to TopMemoryContext before attaching
	 */
	oldcontext = MemoryContextSwitchTo(TopMemoryContext);

	pgsmStateLocal.dsa = dsa_attach_in_place(pgsmStateLocal.shared_pgsmState->raw_dsa_area,
											 NULL);

	/*
	 * pin the attached area to keep the area attached until end of session or
	 * explicit detach.
	 */
	dsa_pin_mapping(pgsmStateLocal.dsa);
	pgsmStateLocal.shared_hash = pgsmStateLocal.shared_pgsmState->hash_handle;
	MemoryContextSwitchTo(oldcontext);
}

dsa_area *
get_dsa_area_for_query_text(void)
{
	pgsm_attach_shmem();
	return pgsmStateLocal.dsa;
}

HTAB *
get_pgsmHash(void)
{
	pgsm_attach_shmem();
	return pgsmStateLocal.shared_hash;
}

pgsmSharedState *
pgsm_get_ss(void)
{
	pgsm_attach_shmem();
	return pgsmStateLocal.shared_pgsmState;
}

pgsmEntry *
hash_entry_alloc(pgsmSharedState *pgsm, const pgsmHashKey *key)
{
	pgsmEntry  *entry;
	bool		found = false;

	/* Find or create an entry with desired hash code */
	entry = (pgsmEntry *) hash_search(pgsmStateLocal.shared_hash, key, HASH_ENTER_NULL, &found);
	if (entry == NULL)
		elog(DEBUG1, "[pg_stat_monitor] hash_entry_alloc: OUT OF MEMORY.");
	else if (!found)
	{
		/* New entry, initialize it */
		/* reset the statistics */
		memset(&entry->counters, 0, sizeof(Counters));
		entry->query_text.query_pos = InvalidDsaPointer;
		entry->counters.info.parent_query = InvalidDsaPointer;
		entry->stats_since = GetCurrentTimestamp();
		entry->minmax_stats_since = entry->stats_since;

		/* set the appropriate initial usage count */
		/* re-initialize the mutex each time ... we assume no one using it */
		SpinLockInit(&entry->mutex);
	}
	return entry;
}

/*
 * Prepare resources for using the new bucket:
 *    - Deallocate hash table entries in the bucket
 *    - Clear query buffer for the bucket
 *
 * Caller must hold an exclusive lock on pgsm->lock.
 */
void
hash_entry_dealloc(int bucket_id)
{
	HASH_SEQ_STATUS hstat;
	pgsmEntry  *entry;

	if (!pgsmStateLocal.shared_hash)
		return;

	/* Iterate over the hash table. */
	hash_seq_init(&hstat, pgsmStateLocal.shared_hash);

	while ((entry = hash_seq_search(&hstat)) != NULL)
	{
		/* Remove all entries if bucket_id == -1 */
		if (bucket_id == INVALID_BUCKET_ID || entry->key.bucket_id == bucket_id)
		{
			dsa_pointer parent_qdsa = entry->counters.info.parent_query;
			dsa_pointer pdsa = entry->query_text.query_pos;

			hash_search(pgsmStateLocal.shared_hash, &entry->key, HASH_REMOVE, NULL);

			if (DsaPointerIsValid(pdsa))
				dsa_free(pgsmStateLocal.dsa, pdsa);

			if (DsaPointerIsValid(parent_qdsa))
				dsa_free(pgsmStateLocal.dsa, parent_qdsa);

			pgsmStateLocal.shared_pgsmState->pgsm_oom = false;
		}
	}
}

bool
IsSystemOOM(void)
{
	return pgsmStateLocal.shared_pgsmState && pgsmStateLocal.shared_pgsmState->pgsm_oom;
}
