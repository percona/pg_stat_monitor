# Changelog

## [Unreleased]

### Added

- Our name and version are now in `pg_get_loaded_modules()` for PostgreSQL 18+
- Support for `EXEC_BACKEND` builds ([PG-2547](https://perconadev.atlassian.net/browse/PG-2547))
- Add PostgreSQL 19 support ([PG-2424](https://perconadev.atlassian.net/browse/PG-2424)): add generic and custom plan counts, support property graphs, use ComputeConstantLengths API for constants squashing
- Backport test cases from pg_stat_statements

### Changed

- Both username and datname are now empty if we cannot get real values ([PG-1459](https://perconadev.atlassian.net/browse/PG-1459))
- Save username and `application_name` before executing commands ([PG-2281](https://perconadev.atlassian.net/browse/PG-2281), [PG-2557](https://perconadev.atlassian.net/browse/PG-2557))
- Add `STABLE`, `LEAKPROOF` and `PARALLEL SAFE` to functions
- Set unit for `pg_stat_monitor.pgsm_query_max_len` to bytes
- Do not leave the `pgsm_create_view()` function after running `CREATE EXTENSION`
- Specifying `USE_PGXS` is no longer necessary when building with make
- Deprecate the `pgsm_track_application_names` parameter, application name now tracked always ([PG-2602](https://perconadev.atlassian.net/browse/PG-2602))
- Show `NULL` instead of `'unknown'` when `application_name` is not set

### Removed

- PostgreSQL 13 support ([PG-2187](https://perconadev.atlassian.net/browse/PG-2187))
- The deprecated `pgsm_overflow_target` GUC parameter ([PG-2279](https://perconadev.atlassian.net/browse/PG-2279))
- Support for non-PGXS builds

### Fixed

- Fix memory leak by scoping local memory context to the current transaction ([PG-2229](https://perconadev.atlassian.net/browse/PG-2229))
- Confusion of `local_blk_read_time` and `local_blk_write_time` where writes were recorded in both fields
- Performance bug when saving `application_name`
- Off-by-one bug in comment extraction ([PG-2485](https://perconadev.atlassian.net/browse/PG-2485))
- Potential buffer overflow with deeply nested queries ([PG-2511](https://perconadev.atlassian.net/browse/PG-2511))
- Potential buffer overread in comment extraction ([PG-2540](https://perconadev.atlassian.net/browse/PG-2540))
- Do not access `PlannedStmt` after we call `standard_ProcessUtility()` ([PG-2486](https://perconadev.atlassian.net/browse/PG-2486))
- Various improvements to the stability of our test suite
- Make sure that for prepared statements utility statement exec info read at the executor start hook, where data is not yet modified by query itself
- Do not acquire LWLock under spinlock
- Race condition where we could leak memory for the parent query
- `plans` now counts only actual planner invocations instead of every execution: utility statements and executions that reuse a cached plan no longer bump the counter
- Normalize the query text of utility statements ([PG-2623](https://perconadev.atlassian.net/browse/PG-2623))

## [2.3.2] - 2026-03-02

### Fixed

- Always truncate query strings at multi-byte character boundaries ([PG-2116](https://perconadev.atlassian.net/browse/PG-2116))
- Fix buffer overflow with high `pgsm_max_buckets`
- Silence some compialtion warnings (Andrei Lepikhov)

## [2.3.1] - 2025-11-27

### Added

- PostgreSQL 18 support ([PG-1907](https://perconadev.atlassian.net/browse/PG-1907))
  - Columns to track parallel worker activity
  - Add tracking of `wal_buffers_full`
  - Support constant lists squashing in query jumbling

## Removed

- PostgreSQL 12 support ([PG-1900](https://perconadev.atlassian.net/browse/PG-1900))

### Fixed

- Fix returned vaules from C function ([PG-1931](https://perconadev.atlassian.net/browse/PG-1931))
- Reduce memory usage by deleteing unnecessary entires from the query stack ([PG-2005](https://perconadev.atlassian.net/browse/PG-2005))
- Fix crash due to unitialized values on the query string stack ([PG-2014](https://perconadev.atlassian.net/browse/PG-2014))

## [2.2.0] - 2025-06-30

### Fixed

- Fix comment removal in query hash calculation ([PG-1674](https://perconadev.atlassian.net/browse/PG-1674))
- Fix performance issue in comment extraction in large queries ([PG-1674](https://perconadev.atlassian.net/browse/PG-1674))
- Fix error levels in PostreSQL 17 ([PG-1313](https://perconadev.atlassian.net/browse/PG-1313))
- Fix bug where `cmd_type` often was 0 ([PG-1621](https://perconadev.atlassian.net/browse/PG-1621))
- Hide sensitive date for users who has no priveleges ([PG-2624](https://perconadev.atlassian.net/browse/PG-2624)).
