#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
PG_BIN_DIR=$(pg_config --bindir)

cd "$SCRIPT_DIR/.."

PG_VERSION=$(pg_config --version | sed -n 's/PostgreSQL \([0-9]*\).*/\1/p')

OPTS='--set shared_preload_libraries=pg_stat_monitor --set unix_socket_directories=/tmp'

if [ "$1" = sanitize ]; then
    OPTS+=' --set max_stack_depth=8MB'
fi

$PG_BIN_DIR/pg_ctl -D regression_install -l regression_install.log init -o "$OPTS"

$PG_BIN_DIR/pg_ctl -D regression_install -l regression_install.log start

make PG_CONFIG=../pginst/bin/pg_config installcheck

$PG_BIN_DIR/pg_ctl -D regression_install stop
