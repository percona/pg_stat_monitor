/*-------------------------------------------------------------------------
 *
 * hash_query.c
 *		Track statement execution times across a whole database cluster.
 *
 * Portions Copyright © 2018-2020, Percona LLC and/or its affiliates
 *
 * Portions Copyright (c) 1996-2020, PostgreSQL Global Development Group
 *
 * Portions Copyright (c) 1994, The Regents of the University of California
 *
 * IDENTIFICATION
 *	  contrib/pg_stat_monitor/hash_query.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "nodes/pg_list.h"

#include "pgsm_errors.h"
#include "pg_stat_monitor.h"


static pgssSharedState *pgss;
static HTAB *pgss_hash;
static HTAB *pgss_query_hash;

static HTAB*
hash_init(const char *hash_name, int key_size, int entry_size, int hash_size)
{
	HASHCTL info;
	memset(&info, 0, sizeof(info));
	info.keysize = key_size;
	info.entrysize = entry_size;
	return ShmemInitHash(hash_name, hash_size, hash_size, &info, HASH_ELEM | HASH_BLOBS);
}

void
pgss_startup(void)
{
	bool		found = false;

	/* reset in case this is a restart within the postmaster */

	pgss = NULL;
	pgss_hash = NULL;

	/*
	* Create or attach to the shared memory state, including hash table
	*/
	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	pgss = ShmemInitStruct("pg_stat_monitor", sizeof(pgssSharedState), &found);
	if (!found)
	{
		/* First time through ... */
		LWLockPadded *pgsm_locks = GetNamedLWLockTranche("pg_stat_monitor");
		pgss->lock = &(pgsm_locks[0].lock);
		pgss->errors_lock = &(pgsm_locks[1].lock);
		pgss->cur_median_usage = ASSUMED_MEDIAN_INIT;
		pgss->qb_overflow = false;
		pgss->n_bucket_cycles = 0;
		pgss->mem_overflow = false;
		SpinLockInit(&pgss->mutex);
		ResetSharedState(pgss);
	}

#ifdef BENCHMARK
	init_hook_stats();
#endif

	set_qbuf((unsigned char *)ShmemAlloc(MAX_QUERY_BUF));

	pgss_hash = hash_init("pg_stat_monitor: bucket hashtable", sizeof(pgssHashKey), sizeof(pgssEntry), MAX_BUCKET_ENTRIES);
	pgss_query_hash = hash_init("pg_stat_monitor: queryID hashtable", sizeof(uint64), sizeof(pgssQueryEntry), MAX_BUCKET_ENTRIES);

	psgm_errors_init();

	LWLockRelease(AddinShmemInitLock);

	/*
	 * If we're in the postmaster (or a standalone backend...), set up a shmem
	 * exit hook to dump the statistics to disk.
	 */
	on_shmem_exit(pgss_shmem_shutdown, (Datum) 0);
}

pgssSharedState*
pgsm_get_ss(void)
{
	return pgss;
}

HTAB*
pgsm_get_hash(void)
{
	return pgss_hash;
}

HTAB*
pgsm_get_query_hash(void)
{
	return pgss_query_hash;
}

/*
 * shmem_shutdown hook: Dump statistics into file.
 *
 * Note: we don't bother with acquiring lock, because there should be no
 * other processes running when this is called.
 */
void
pgss_shmem_shutdown(int code, Datum arg)
{
	/* Don't try to dump during a crash. */
	if (code)
		return;

	pgss = NULL;
	/* Safety check ... shouldn't get here unless shmem is set up. */
	if (!IsHashInitialize())
		return;
}

Size
hash_memsize(void)
{
	Size	size;

	size = MAXALIGN(sizeof(pgssSharedState));
	size += MAXALIGN(MAX_QUERY_BUF);
	size = add_size(size, hash_estimate_size(MAX_BUCKET_ENTRIES, sizeof(pgssEntry)));
	size = add_size(size, hash_estimate_size(MAX_BUCKET_ENTRIES, sizeof(pgssQueryEntry)));

	return size;
}

/*
 * qsort comparator for sorting query entries into increasing usage order.
 *
 * lhs and rhs are the addresses of the values to be sorted.
 * Since the values themselves are uintptr_t representing pointers to queries
 * in the query shared buffer and we want to sort by usage and not by the
 * uintptr_t value, we need another level of indirection to extract the usage field.
 * The usage field is a double located right after the QueryID (uint64).
 */
static int
entry_cmp_usage(const void *lhs, const void *rhs)
{
	double l_usage;
	double r_usage;
	uintptr_t l = *(uintptr_t *)lhs;
	uintptr_t r = *(uintptr_t *)rhs;

	const char *lptr = (const char *)l;
	const char *rptr = (const char *)r;

	/* skip query id, usage is right next to it, */
	lptr += sizeof(uint64);
	rptr += sizeof(uint64);

	l_usage = *(double *)lptr;
	r_usage = *(double *)rptr;

	if (l_usage < r_usage)
		return -1;
	else if (l_usage > r_usage)
		return 1;
	else
		return 0;
}

/*
 * Deallocate least-used entries, both from the hash table (pgss_hash)
 * and the shared query buffer (pgsm_query_shared_buffer).
 *
 * Caller must hold an exclusive lock on pgss->lock.
 */
void entry_dealloc(unsigned char *qbuffer)
{
	HASH_SEQ_STATUS hash_seq;
	pgssEntry  *entry;
	int			nvictims;
	int			num_queries;
	int			num_entries;
	uintptr_t	*entries_sorted;
	char *tmp_qbuffer;
	uint64		qbuf_len;
	uint64		qbuf_pos;
	HTAB		*ht_entries_to_keep;  /* Elements that will be kept. */
	HASHCTL		ctl;

	/* Hash table entry for elements that won't be removed. */
	struct query_entry {
		uint64 query_id; /* hash key */
		size_t query_pos;
	};

	num_entries = hash_get_num_entries(pgss_hash);

	/*
	 * Create an array of pointers to query entries into the query buffer.
	 * Sort entries by usage and deallocate USAGE_DEALLOC_PERCENT of them.
	 * While we're scanning the query buffer entries, apply the decay factor
	 * to the usage values.
	 */
	entries_sorted = palloc(num_entries * (sizeof(uintptr_t)));

	hash_seq_init(&hash_seq, pgss_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		/* "Sticky" entries get a different usage decay rate. */
		if (IS_STICKY(entry->counters))
			*(double *)&qbuffer[entry->query_pos + sizeof(uint64)] *= STICKY_DECREASE_FACTOR;
		else
			*(double *)&qbuffer[entry->query_pos + sizeof(uint64)] *= USAGE_DECREASE_FACTOR;
	}

	qbuf_len = *(uint64 *)qbuffer;
	qbuf_pos = sizeof(uint64);

	num_queries = 0;
	while (qbuf_pos < qbuf_len && num_queries < num_entries)
	{
		uint64 qlen;
		entries_sorted[num_queries++] = (uintptr_t) &qbuffer[qbuf_pos];
		qbuf_pos += sizeof(uint64); /* query id. */
		qbuf_pos += sizeof(double); /* usage. */
		qlen = *(uint64 *)&qbuffer[qbuf_pos]; /* query length. */
		qbuf_pos += sizeof(uint64) + qlen;
	}

	/* Sort into increasing order by usage */
	qsort(entries_sorted, num_queries, sizeof(uintptr_t), entry_cmp_usage);

	/* Record the (approximate) median usage */
	if (num_queries > 0)
	{
		unsigned char *ptr = (unsigned char *)entries_sorted[num_queries / 2];
		ptr += sizeof(uint64); /* skip query id. */
		pgss->cur_median_usage = *(double *)ptr;
	}

	/* Now zap an appropriate fraction of lowest-usage entries */
	nvictims = Max(10, num_queries * USAGE_DEALLOC_PERCENT / 100);
	nvictims = Min(nvictims, num_queries);

	tmp_qbuffer = palloc(MAX_QUERY_BUF);

	ctl.keysize = sizeof(uint64);
	ctl.entrysize = sizeof(struct query_entry);
	ht_entries_to_keep = hash_create("tmp_query_entries",
									 num_queries - nvictims,
									 &ctl,
									 HASH_ELEM | HASH_BLOBS);

	/*
	 * Now entries_sorted array is sorted such that:
	 * elements from 0..(nvictims -1) must be removed (low usage).
	 * elements from nvictims..num_queries must be kept.
	 * Save queries that won't be removed into temporary query buffer.
	 */
	qbuf_pos = sizeof(uint64);
	for (int i = nvictims; i < num_queries; ++i)
	{
		struct query_entry *entry;
		bool found = false;
		uint64 query_id;
		uint64 qlen;
		unsigned char *src = (unsigned char *)entries_sorted[i];

		query_id = *(uint64 *)src;
		entry = hash_search(ht_entries_to_keep, &query_id, HASH_ENTER, &found);
		if (!found)
			entry->query_pos = qbuf_pos;  /* Update query position. */

		/* Copy QueryID, usage and query length. */
		memcpy(&tmp_qbuffer[qbuf_pos], src, sizeof(uint64) + sizeof(double) + sizeof(uint64));

		qbuf_pos += sizeof(uint64) + sizeof(double) + sizeof(uint64);
		src += sizeof(uint64) + sizeof(double);

		/* Copy query text. */
		qlen = *(uint64 *)src;
		src += sizeof(uint64);
		memcpy(&tmp_qbuffer[qbuf_pos], src, qlen);

		src += qlen;
		qbuf_pos += qlen;
	}

	/* Adjust total buffer length. */
	*(uint64 *)tmp_qbuffer = qbuf_pos;

	/* Overwrite original query buffer with updated query buffer. */
	memcpy(qbuffer, tmp_qbuffer, qbuf_pos);

	/* Remove elements with low usage, update query positions of elements kept. */
	hash_seq_init(&hash_seq, pgss_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		struct query_entry *match;

		match = hash_search(ht_entries_to_keep,
							&(entry->key.queryid),
							HASH_FIND, NULL);

		if (match != NULL)
			/* Entry must be kept, update query position. */
			entry->query_pos = match->query_pos;
		else
			/* If can't locate queryid then the entry must be removed. */
			hash_search(pgss_hash, &entry->key, HASH_REMOVE, NULL);
	}

	hash_destroy(ht_entries_to_keep);
	pfree(entries_sorted);
}

pgssEntry *
hash_entry_alloc(pgssSharedState *pgss,
	pgssHashKey *key,
	int encoding,
	unsigned char *qbuffer)
{
	pgssEntry	*entry = NULL;
	bool		found = false;

	/* Make space if needed */
	if (hash_get_num_entries(pgss_hash) >= MAX_BUCKET_ENTRIES)
	{
		if (pgss->mem_overflow)
		{
			/*
			 * Avoid cleaning least used entries if hash table overflowed again
			 * and we are still in the same bucket number.
			 */
			return NULL;
		}
		else
		{
			pgss->mem_overflow = true;
			entry_dealloc(qbuffer);
		}
	}

	/* Find or create an entry with desired hash code */
	entry = (pgssEntry *) hash_search(pgss_hash, key, HASH_ENTER_NULL, &found);
	if (entry != NULL && !found)
	{
		/* New entry, initialize it */
		pgss->bucket_entry[pg_atomic_read_u64(&pgss->current_wbucket)]++;

		/* reset the statistics */
		memset(&entry->counters, 0, sizeof(Counters));

		/* re-initialize the mutex each time ... we assume no one using it */
		SpinLockInit(&entry->mutex);
		/* ... and don't forget the query text metadata */
		entry->encoding = encoding;
	}

	return entry;
}

/*
 * Prepare resources for using the new bucket:
 *    - Deallocate finished hash table entries in new_bucket_id (entries whose
 *      state is PGSS_FINISHED or PGSS_FINISHED).
 *    - Clear query buffer for new_bucket_id.
 *    - If old_bucket_id != -1, move all pending hash table entries in
 *      old_bucket_id to the new bucket id, also move pending queries from the 
 *      previous query buffer (query_buffer[old_bucket_id]) to the new one
 *      (query_buffer[new_bucket_id]).
 *
 * Caller must hold an exclusive lock on pgss->lock.
 */
void
hash_entry_dealloc(int new_bucket_id, int old_bucket_id, unsigned char *query_buffer)
{
	HASH_SEQ_STATUS hash_seq;
	pgssEntry		*entry = NULL;

	/* Store pending query ids from the previous bucket. */
	List        *pending_entries = NIL;
	ListCell    *pending_entry;

	/* Iterate over the hash table. */
	hash_seq_init(&hash_seq, pgss_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		/*
		 * Remove all entries if new_bucket_id == -1.
		 * Otherwise remove entry in new_bucket_id if it has finished already.
		 */
		if (new_bucket_id < 0 ||
			(entry->key.bucket_id == new_bucket_id &&
			entry->counters.state != PGSS_INVALID))
		{
			if (new_bucket_id == -1) {
				/* pg_stat_monitor_reset(), remove entry from query hash table too. */
				hash_search(pgss_query_hash, &(entry->key.queryid), HASH_REMOVE, NULL);
			}

			entry = hash_search(pgss_hash, &entry->key, HASH_REMOVE, NULL);
		}

		/*
		 * If we detect a pending query residing in the previous bucket id,
		 * we add it to a list of pending elements to be moved to the new
		 * bucket id.
		 * Can't update the hash table while iterating it inside this loop,
		 * as this may introduce all sort of problems.
		 */
		if (entry->key.bucket_id == old_bucket_id && IS_STICKY(entry->counters))
		{
			pgssEntry *bkp_entry = malloc(sizeof(pgssEntry));
			if (!bkp_entry)
			{
				pgsm_log_error("hash_entry_dealloc: out of memory");
				entry = hash_search(pgss_hash, &entry->key, HASH_REMOVE, NULL);
				continue;
			}

			/* Save key/data from the previous entry. */
			memcpy(bkp_entry, entry, sizeof(pgssEntry));

			/* Update key to use the new bucket id. */
			bkp_entry->key.bucket_id = new_bucket_id;

			/* Add the entry to a list of nodes to be processed later. */
			pending_entries = lappend(pending_entries, bkp_entry);

			entry = hash_search(pgss_hash, &entry->key, HASH_REMOVE, NULL);
		}
	}

	/*
	 * Iterate over the list of pending queries in order
	 * to add them back to the hash table with the updated bucket id.
	 */
	foreach (pending_entry, pending_entries) {
		bool found = false;
		pgssEntry	*new_entry;
		pgssEntry	*old_entry = (pgssEntry *) lfirst(pending_entry);

		new_entry = (pgssEntry *) hash_search(pgss_hash, &old_entry->key, HASH_ENTER_NULL, &found);
		if (new_entry == NULL)
			pgsm_log_error("hash_entry_dealloc: out of memory");
		else if (!found)
		{
			/* Restore counters and other data. */
			new_entry->counters = old_entry->counters;
			SpinLockInit(&new_entry->mutex);
			new_entry->encoding = old_entry->encoding;
			new_entry->query_pos = old_entry->query_pos;
		}

		free(old_entry);
	}

	list_free(pending_entries);
}

/*
 * Release all entries.
 */
void
hash_entry_reset()
{
	pgssSharedState *pgss   = pgsm_get_ss();
	HASH_SEQ_STATUS		hash_seq;
	pgssEntry			*entry;

	LWLockAcquire(pgss->lock, LW_EXCLUSIVE);

	hash_seq_init(&hash_seq, pgss_hash);
	while ((entry = hash_seq_search(&hash_seq)) != NULL)
	{
		hash_search(pgss_hash, &entry->key, HASH_REMOVE, NULL);
	}
	pg_atomic_write_u64(&pgss->current_wbucket, 0);
	LWLockRelease(pgss->lock);
}

bool
IsHashInitialize(void)
{
	return (pgss != NULL &&
			pgss_hash != NULL);
}
