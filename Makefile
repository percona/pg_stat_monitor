MODULE_big = pg_stat_monitor
OBJS = src/hash_query.o src/guc.o src/pg_stat_monitor.o $(WIN32RES)

EXTENSION = pg_stat_monitor
DATA = pg_stat_monitor--2.0.sql \
	pg_stat_monitor--1.0--2.0.sql pg_stat_monitor--2.0--2.1.sql \
	pg_stat_monitor--2.1--2.2.sql pg_stat_monitor--2.2--2.3.sql \
	pg_stat_monitor--2.3--next.sql

PGFILEDESC = "pg_stat_monitor - Query Performance Monitoring Tool for PostgreSQL"

LDFLAGS_SL += $(filter -lm, $(LIBS))

TAP_TESTS = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
