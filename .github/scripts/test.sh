#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"

cd "$SCRIPT_DIR/../../"

PG_VERSION=$(pg_config --version | sed -n 's/PostgreSQL \([0-9]*\).*/\1/p')

if [ "$1" = sanitize ]; then
    export PG_TEST_INITDB_EXTRA_OPTS='--set max_stack_depth=8MB'
fi

make installcheck PROVE_FLAGS=-f
