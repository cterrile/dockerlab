#!/usr/bin/env bash
# Utility functions for resolving which stacks changed and which hosts
# they map to. Sourced by the deploy workflow — not run directly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resolve_hosts() {
  local changed_stacks="${1:-all}"

  if [ "$changed_stacks" = "all" ]; then
    echo "all"
    return
  fi

  local hosts=()
  IFS=',' read -ra stacks <<< "$changed_stacks"

  for stack in "${stacks[@]}"; do
    local infra_file="$REPO_ROOT/stacks/$stack/infra.yml"
    if [ -f "$infra_file" ]; then
      local host
      host=$(grep -m1 '^host:' "$infra_file" | awk '{print $2}' | tr -d '[:space:]')
      if [ -n "$host" ]; then
        hosts+=("$host")
      fi
    else
      echo "Warning: no infra.yml for stack '$stack'" >&2
    fi
  done

  if [ ${#hosts[@]} -eq 0 ]; then
    echo "all"
    return
  fi

  # Deduplicate and join with comma (Ansible --limit format)
  printf '%s\n' "${hosts[@]}" | sort -u | paste -sd,
}

resolve_changed_stacks() {
  local base_ref="${1:-HEAD~1}"
  local head_ref="${2:-HEAD}"

  git diff --name-only "$base_ref" "$head_ref" -- stacks/ \
    | cut -d'/' -f2 \
    | sort -u \
    | paste -sd,
}
