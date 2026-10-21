#!/bin/bash

set -e

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

DEPS=(
    # Setup
    wget

    # Build
    gnu-sed

    # Run pgperltidy
    perltidy

    # Perl dependencies
    cpanminus
)

brew install "${DEPS[@]}"
cpanm --notest --quiet IPC::Run Text::Trim JSON
