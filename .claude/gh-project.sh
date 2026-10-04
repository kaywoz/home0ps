#!/usr/bin/env bash
# Runs `gh project ...` with the project-scoped classic token from the macOS
# Keychain (service gh-project-token). Fine-grained tokens can't write to
# user-owned projects; the token never appears on the command line.
set -euo pipefail
GH_TOKEN="$(security find-generic-password -s gh-project-token -w)" exec gh project "$@"
