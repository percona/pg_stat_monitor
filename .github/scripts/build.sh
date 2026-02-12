#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
PG_CFLAGS=-Werror

cd "$SCRIPT_DIR/../.."

case "$1" in
    debug)
        echo "Building with debug option"
        ;;

    debugoptimized)
        echo "Building with debugoptimized option"
        PG_CFLAGS+=" -O2"
        ;;

    sanitize)
        echo "Building with sanitize option"
        PG_CFLAGS+=" -fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer -fno-inline-functions"
        ;;

    coverage)
        echo "Building with coverage option"
        PG_CFLAGS+=" -g -fprofile-arcs -ftest-coverage"
        ;;

    *)
        echo "Unknown build type: $1"
        echo "Please use one of the following: debug, debugoptimized, sanitize"
        exit 1
        ;;
esac

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    NCPU=$(nproc)
elif [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(sysctl -n hw.ncpu)
fi

sudo env "PATH=$PATH" PG_CFLAGS="$PG_CFLAGS" make USE_PGXS=1 install -j $NCPU
