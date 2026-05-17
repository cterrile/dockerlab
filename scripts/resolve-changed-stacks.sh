#!/usr/bin/env bash
# Utility functions for resolving stack → host mappings.
# Sourced by the deploy DAG — not run directly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_host() {
  local stack="${1:?Usage: resolve_host <stack_name>}"
  local infra_file="$REPO_ROOT/stacks/$stack/infra.yml"

  if [ ! -f "$infra_file" ]; then
    echo "Warning: no infra.yml for stack '$stack'" >&2
    echo "all"
    return
  fi

  local host
  host=$(grep -m1 '^host:' "$infra_file" | awk '{print $2}' | tr -d '[:space:]')

  if [ -n "$host" ]; then
    echo "$host"
  else
    echo "all"
  fi
}
