#!/usr/bin/env sh
set -eu

# Ensure WORKSPACE_ROOT exists by default
: "${WORKSPACE_ROOT:=.}"

exec bats "$WORKSPACE_ROOT/e2e" \
  --recursive \
  --timing \
  --print-output-on-failure