#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

cd "$SCRIPT_DIR/.."

PG_VERSION=$(pg_config --version | sed -n 's/PostgreSQL \([0-9]*\).*/\1/p')

OPTS='--set shared_preload_libraries=pg_stat_monitor'

if [ "$1" = sanitize ]; then
    OPTS+=' --set max_stack_depth=8MB'
fi

pg_ctl -D regress_install -l regress_install.log init -o "$OPTS"

pg_ctl -D regress_install -l regress_install.log start

make PG_CONFIG=../pginst/bin/pg_config installcheck

pg_ctl -D regress_install stop
