#!/bin/bash

set -e

SCRIPT_DIR=$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)
INSTALL_DIR=${PG_INSTALL_DIR:-/usr/local/pgsql}
PG_SOURCE_DIR=${PG_SOURCE_DIR:-$SCRIPT_DIR/../../../postgres}
cd "$SCRIPT_DIR/../.."

if ! test -f typedefs-full.list; then
  echo "typedefs-full.list doesn't exists, run dump-typedefs.sh first"
  exit 1
fi

cd "$PG_SOURCE_DIR"/src/tools/pg_bsd_indent
sudo make install

cd "$SCRIPT_DIR/../.."

export PATH=$PG_SOURCE_DIR/src/tools/pgindent/:$INSTALL_DIR/bin/:$PATH

# Check pg_stat_monitor with the fresh list extraxted from the object file
pgindent --typedefs=typedefs-full.list --excludes=<(echo "src/libkmip") "$@" .
