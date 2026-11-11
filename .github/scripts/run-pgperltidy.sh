#!/bin/bash

set -e

SCRIPT_DIR=$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)
PG_SOURCE_DIR=${PG_SOURCE_DIR:-$SCRIPT_DIR/../../../postgres}
cd "$SCRIPT_DIR/../.."

source "$PG_SOURCE_DIR"/src/tools/perlcheck/find_perl_files

find_perl_files . | xargs perltidy "$@" --profile="$PG_SOURCE_DIR"/src/tools/pgindent/perltidyrc
