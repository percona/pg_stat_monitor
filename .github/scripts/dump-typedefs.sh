#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
cd "$SCRIPT_DIR/../.."

if ! test -f pg_stat_monitor.so; then
  echo "pg_stat_monitor.so doesn't exists, run build.sh first in debug mode"
  exit 1
fi

../postgres/src/tools/find_typedef . >> typedefs.list

# Fetches typedefs list for PostgreSQL core and merges it with typedefs defined in this project.
# https://wiki.postgresql.org/wiki/Running_pgindent_on_non-core_code_or_development_code
(wget -q -O - "https://buildfarm.postgresql.org/cgi-bin/typedefs.pl?branch=REL_17_STABLE"; wget -q -O - "https://buildfarm.postgresql.org/cgi-bin/typedefs.pl?branch=REL_18_STABLE") | cat - typedefs.list | sort -u > typedefs-full.list
