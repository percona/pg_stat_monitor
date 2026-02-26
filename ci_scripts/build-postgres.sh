#!/bin/bash

set -e

ARGS=

SCRIPT_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P)"
PSP_DIR="$SCRIPT_DIR/../../postgres"

case "$1" in
    debug)
        echo "Building with debug option"
        ARGS+=" --enable-cassert --enable-injection-points"
        ;;

    debugoptimized)
        echo "Building with debugoptimized option"
        export CFLAGS="-O2"
        ARGS+=" --enable-cassert --enable-injection-points"
        ;;

    coverage)
        echo "Building with coverage option"
        ARGS+=" --enable-cassert --enable-injection-points --enable-coverage"
        ;;

    sanitize)
        echo "Building with sanitize option"
        export CFLAGS="-fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer -fno-inline-functions"
        ;;

    *)
        echo "Unknown build type: $1"
        echo "Please use one of the following: debug, debugoptimized, sanitize"
        exit 1
        ;;
esac

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    ARGS+=" --with-liburing"
    NCPU=$(nproc)
elif [[ "$OSTYPE" == "darwin"* ]]; then
    NCPU=$(sysctl -n hw.ncpu)
fi

cd "$PSP_DIR"

./configure \
   --enable-debug \
   --enable-tap-tests \
   $ARGS

sudo make install-world -s -j $NCPU
