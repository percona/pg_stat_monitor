# Copyright (c) 2022-2023, PostgreSQL Global Development Group

pg_stat_monitor_sources = files(
  'src/pg_stat_monitor.c',
  'src/hash_query.c',
  'src/guc.c',
)

pg_stat_monitor = shared_module('pg_stat_monitor',
  pg_stat_monitor_sources,
  kwargs: contrib_mod_args + {
    'dependencies': contrib_mod_args['dependencies'],
  },
)
contrib_targets += pg_stat_monitor

install_data(
  'pg_stat_monitor.control',
  'pg_stat_monitor--2.0.sql',
  'pg_stat_monitor--1.0--2.0.sql',
  'pg_stat_monitor--2.0--2.1.sql',
  'pg_stat_monitor--2.1--2.2.sql',
  'pg_stat_monitor--2.2--2.3.sql',
  'pg_stat_monitor--2.3--next.sql',
  kwargs: contrib_data_args,
)
