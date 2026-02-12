#!/bin/bash

set -e

DEPS=(
    # Setup
    wget
    # Build
    gnu-sed

    # Run pgperltidy
    perltidy
)

brew update
brew install ${DEPS[@]}

cpan IPC::Run JSON
