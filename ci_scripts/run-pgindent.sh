#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
INSTALL_DIR="$SCRIPT_DIR/../../pginst"
cd "$SCRIPT_DIR/../"

if ! test -f typedefs-full.list; then
  echo "typedefs-full.list doesn't exists, run dump-typedefs.sh first"
  exit 1
fi

cd ../postgres/src/tools/pg_bsd_indent
make install

cd "$SCRIPT_DIR/.."

export PATH=$SCRIPT_DIR/../../postgres/src/tools/pgindent/:$INSTALL_DIR/bin/:$PATH

# Check pg_tde with the fresh list extraxted from the object file
pgindent --typedefs=typedefs-full.list --excludes=<(echo "src/libkmip") "$@" .
