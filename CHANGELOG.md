# Changelog

## [Unreleased]

### Added

- Support for `EXEC_BACKEND` builds ([PG-2547](https://perconadev.atlassian.net/browse/PG-2547))


### Changed

- Do not leave the `pgsm_create_view()` function after running `CREATE EXTENSION`
- Read utility statement exec info before executing this statement ([PG-2557](https://perconadev.atlassian.net/browse/PG-2557))

### Fixed

- Fix memory leak by scoping local memory context to the current transaction ([PG-2229](https://perconadev.atlassian.net/browse/PG-2229))
