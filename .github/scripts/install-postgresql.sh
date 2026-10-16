#!/bin/bash

set -e

if [ -z "$2" ]; then
    echo "Error: The second argument (PostgreSQL version) must be provided."
    exit 1
fi

case "$1" in
    pgdg-macos)
        echo "Installing PostgreSQL from PostgreSQL Global Development Group (PGDG) Distribution on macOS"
        brew install postgresql@${2}
        brew link postgresql@${2}
        ;;

    *)
        echo "Unknown PostgreSQL distribution type: $1"
        echo "Please use one of the following: pgdg-macos"
        exit 1
        ;;
esac
