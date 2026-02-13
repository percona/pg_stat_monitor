#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
cd "$SCRIPT_DIR/../"

source ../postgres/src/tools/perlcheck/find_perl_files

find_perl_files . | xargs perltidy "$@" --profile=../postgres/src/tools/pgindent/perltidyrc
