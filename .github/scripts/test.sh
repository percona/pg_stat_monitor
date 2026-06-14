#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
PG_BIN_DIR=$(pg_config --bindir)

cd "$SCRIPT_DIR/../../"

OPTS='-c shared_preload_libraries=pg_stat_monitor'

if [ "$1" = sanitize ]; then
    OPTS+=' -c max_stack_depth=8MB'
fi

$PG_BIN_DIR/pg_ctl -D regression_install -l regression_install.log init

$PG_BIN_DIR/pg_ctl -D regression_install -l regression_install.log start -o "$OPTS"

make installcheck

$PG_BIN_DIR/pg_ctl -D regression_install stop
