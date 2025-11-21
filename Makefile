# contrib/pg_stat_monitor/Makefile

MODULE_big = pg_stat_monitor
OBJS = hash_query.o guc.o pg_stat_monitor.o $(WIN32RES)

EXTENSION = pg_stat_monitor
DATA = pg_stat_monitor--2.0.sql pg_stat_monitor--1.0--2.0.sql pg_stat_monitor--2.0--2.1.sql pg_stat_monitor--2.1--2.2.sql pg_stat_monitor--2.2--2.3.sql

PGFILEDESC = "pg_stat_monitor - execution statistics of SQL statements"
PG_CFLAGS += -O0 -g
LDFLAGS_SL += $(filter -lm, $(LIBS)) 

TAP_TESTS = 1
EXTRA_INSTALL = contrib/pg_stat_statements
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
	level_tracking \
	decode_error_level \
	parallel

# Disabled because these tests require "shared_preload_libraries=pg_stat_statements",
# which typical installcheck users do not have (e.g. buildfarm clients).
# NO_INSTALLCHECK = 1

PG_CONFIG ?= pg_config

ifdef USE_PGXS
MAJORVERSION := $(shell $(PG_CONFIG) --version | awk {'print $$2'} | cut -f1 -d".")
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_stat_monitor
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

# Fetches typedefs list for PostgreSQL core and merges it with typedefs defined in this project.
# https://wiki.postgresql.org/wiki/Running_pgindent_on_non-core_code_or_development_code
update-typedefs:
	wget -q -O - "https://buildfarm.postgresql.org/cgi-bin/typedefs.pl?branch=REL_17_STABLE" | cat - typedefs.list | sort | uniq > typedefs-full.list

# Indents projects sources.
indent:
	pgindent --typedefs=typedefs-full.list .

.PHONY: update-typedefs indent