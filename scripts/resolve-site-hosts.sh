#!/usr/bin/env bash
# Utility functions for site tools host registry (site/hosts.yml).
# Sourced by the push-tools DAG — not run directly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_HOSTS_FILE="${SITE_HOSTS_FILE:-$REPO_ROOT/site/hosts.yml}"

list_site_hosts() {
  if [ ! -f "$SITE_HOSTS_FILE" ]; then
    echo "ERROR: site hosts registry not found: $SITE_HOSTS_FILE" >&2
    return 1
  fi

  awk '
    /^hosts:/ { in_hosts = 1; next }
    in_hosts && /^  [a-zA-Z0-9_-]+:$/ {
      gsub(/^  /, "", $0)
      gsub(/:$/, "", $0)
      print
      next
    }
    in_hosts && /^[^ ]/ { exit }
  ' "$SITE_HOSTS_FILE" | paste -sd, -
}

get_site_infisical_path() {
  local host="${1:?Usage: get_site_infisical_path <hostname>}"

  if [ ! -f "$SITE_HOSTS_FILE" ]; then
    echo "ERROR: site hosts registry not found: $SITE_HOSTS_FILE" >&2
    return 1
  fi

  local path
  path="$(awk -v h="$host" '
    $0 ~ "^  " h ":$" { found = 1; next }
    found && /^    infisical_path:/ { print $2; exit }
    found && /^  [a-zA-Z0-9_-]+:/ { exit }
  ' "$SITE_HOSTS_FILE")"

  if [ -n "$path" ]; then
    echo "$path"
  else
    echo "/sites/$host"
  fi
}

host_in_site_registry() {
  local host="${1:?Usage: host_in_site_registry <hostname>}"
  list_site_hosts | tr ',' '\n' | grep -qx "$host"
}
