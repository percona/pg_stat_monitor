#!/bin/bash

set -e

# `brew update` re-syncs the whole formula index on every job for dependencies
# that are already current in the runner image. Skipping it, and suppressing the
# implicit update that `brew install` would otherwise trigger, is the bulk of
# the saving here.
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

    # Install the Perl test dependencies below
    cpanminus
)

brew install "${DEPS[@]}"

# cpanm resolves and installs in one pass; plain `cpan` reconfigures and
# re-indexes CPAN on first use. --notest matches the intent of `cpan -T`.
cpanm --notest --quiet IPC::Run Text::Trim JSON

# cpanm installs into the perl it was built against, which is not necessarily
# the perl that runs the TAP suite. Fail loudly here rather than leaving the
# tests to die on a missing module much later.
perl -MIPC::Run -MText::Trim -MJSON -e 'exit 0'
