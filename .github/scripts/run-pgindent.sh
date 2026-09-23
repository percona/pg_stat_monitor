#!/bin/bash

set -e

SCRIPT_DIR=$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)
INSTALL_DIR=$SCRIPT_DIR/../../pginst
PG_SOURCE_DIR=${PG_SOURCE_DIR:-$SCRIPT_DIR/../../../postgres}
# Absent when running as root in a container.
SUDO=$(command -v sudo || true)
cd "$SCRIPT_DIR/../.."

if ! test -f typedefs-full.list; then
  echo "typedefs-full.list doesn't exists, run dump-typedefs.sh first"
  exit 1
fi

# Prebuilt CI images already ship pg_bsd_indent, and their PostgreSQL tree has
# been cleaned of object files, so only build it when it is actually missing.
if ! command -v pg_bsd_indent >/dev/null; then
    $SUDO make -C "$PG_SOURCE_DIR"/src/tools/pg_bsd_indent install
fi

cd "$SCRIPT_DIR/../.."

export PATH=$PG_SOURCE_DIR/src/tools/pgindent/:$INSTALL_DIR/bin/:$PATH

# Check pg_stat_monitor with the fresh list extraxted from the object file
pgindent --typedefs=typedefs-full.list --excludes=<(echo "src/libkmip") "$@" .
