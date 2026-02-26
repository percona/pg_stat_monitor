#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
CFLAGS=-Werror

cd "$SCRIPT_DIR/.."

case "$1" in
    debug)
        echo "Building with debug option"
        ;;

    debugoptimized)
        echo "Building with debugoptimized option"
        CFLAGS+=" -O2"
        ;;

    sanitize)
        echo "Building with sanitize option"
        CFLAGS+=" -fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer -fno-inline-functions"
        ;;

    *)
        echo "Unknown build type: $1"
        echo "Please use one of the following: debug, debugoptimized, sanitize"
        exit 1
        ;;
esac

echo $GITHUB_PATH


export CFLAGS
sudo make USE_PGXS=1 install -j
