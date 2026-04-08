MODULE_big = pg_stat_monitor
OBJS = hash_query.o guc.o pg_stat_monitor.o $(WIN32RES)

EXTENSION = pg_stat_monitor
DATA = pg_stat_monitor--2.0.sql \
	pg_stat_monitor--1.0--2.0.sql pg_stat_monitor--2.0--2.1.sql \
	pg_stat_monitor--2.1--2.2.sql pg_stat_monitor--2.2--2.3.sql \
	pg_stat_monitor--2.3--2.4.sql

PGFILEDESC = "pg_stat_monitor - Query Performance Monitoring Tool for PostgreSQL"

LDFLAGS_SL += $(filter -lm, $(LIBS))

TAP_TESTS = 1
REGRESS_OPTS = --temp-config $(top_srcdir)/contrib/pg_stat_monitor/pg_stat_monitor.conf --inputdir=regression
REGRESS = basic \
	version \
	guc \
	pgsm_query_id \
	functions \
	counters \
	relations \
	database \
	error_insert \
	application_name \
	application_name_unique \
	top_query \
	different_parent_queries \
	cmd_type \
	error \
	rows \
	squashing \
	tags \
	user \
	rollback \
	level_tracking \
	decode_error_level \
	parallel \
	histogram

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
