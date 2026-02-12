#!/bin/bash

set -e

DEPS=(
    # Setup
    wget
    # Build
    perl

    # Test
    libipc-run-perl
    # Run pgperltidy
    perltidy
)

sudo apt-get update
sudo apt-get install -y ${DEPS[@]}
