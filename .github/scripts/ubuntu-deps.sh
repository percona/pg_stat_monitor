#!/bin/bash

set -e

DEPS=(
    # Setup
    wget

    # Build
    perl
    libkrb5-dev

    # Test
    libipc-run-perl
    libjson-perl
    libtext-trim-perl

    # Run pgperltidy
    perltidy
)

sudo apt-get update
sudo apt-get install -y ${DEPS[@]}
