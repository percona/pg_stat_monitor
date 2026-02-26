#!/bin/bash

set -e

DEPS=(
    # Setup
    wget
    # Build
    perl

    # Test
    libipc-run-perl
    libtext-trim-perl
    libjson-perl
    # Run pgperltidy
    perltidy
)

case "$1" in
    dev)
        DEPS+=(
            # Build
            bison
            docbook-xml
            docbook-xsl
            flex
            gettext
            libicu-dev
            libkrb5-dev
            libldap2-dev
            liblz4-dev
            libpam0g-dev
            libperl-dev
            libreadline-dev
            libselinux1-dev
            libssl-dev
            libsystemd-dev
            liburing-dev
            libxml2-dev
            libxml2-utils
            libxslt1-dev
            libzstd-dev
            lz4
            mawk
            perl
            pkgconf
            systemtap-sdt-dev
            tcl-dev
            uuid-dev
            xsltproc
            zlib1g-dev
            zstd
            )
        ;;
esac

sudo apt-get update
sudo apt-get install -y ${DEPS[@]}
