# Changelog

## [Unreleased]

### Added

- Our name and version are now in `pg_get_loaded_modules()` for PostgreSQL 18+
- Support for `EXEC_BACKEND` builds ([PG-2547](https://perconadev.atlassian.net/browse/PG-2547))

### Changed

- Both username and datname are now empty if we cannont get real values ([PG-1459](https://perconadev.atlassian.net/browse/PG-1459))
- Save username and `application_name` before executing commands ([PG-2281](https://perconadev.atlassian.net/browse/PG-2281), [PG-2557](https://perconadev.atlassian.net/browse/PG-2557))
- Set unit for `pg_stat_monitor.pgsm_query_max_len` to bytes
- Do not leave the `pgsm_create_view()` function after running `CREATE EXTENSION`
- Specifying `USE_PGXS` is no longer necessary when building with make

### Removed

- PostgreSQL 13 support ([PG-2187](https://perconadev.atlassian.net/browse/PG-2187))
- The deprecated `pgsm_overflow_target` GUC parameter ([PG-2279](https://perconadev.atlassian.net/browse/PG-2279))
- Support for non-PGXS builds

### Fixed

- Fix memory leak by scoping local memory context to the current transaction ([PG-2229](https://perconadev.atlassian.net/browse/PG-2229))
- Confusion of `local_blk_read_time` and `local_blk_write_time` where writes were recorded in both fields
- Performance bug when saving `application_name`
- Off-by-one bug in comment extraction ([PG-2485](https://perconadev.atlassian.net/browse/PG-2485))
- Potential buffer overflow with deeply nested quries ([PG-2511](https://perconadev.atlassian.net/browse/PG-2511))
- Potential buffer overread in comment extraction ([PG-2540](https://perconadev.atlassian.net/browse/PG-2540))
- Do not access `PlannedStmt` after we call `standard_ProcessUtility()` ([PG-2486](https://perconadev.atlassian.net/browse/PG-2486))
- Various improvements to the stability of our test suite
