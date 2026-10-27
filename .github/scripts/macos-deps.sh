#!/bin/bash

set -e

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

DEPS=(
    # Setup
    wget

    # Build
    gnu-sed

    # Run pgperltidy
    perltidy
)

brew install "${DEPS[@]}"

cpan -T IPC::Run Text::Trim JSON
