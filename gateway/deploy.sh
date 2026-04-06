#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found (usually from gettext). macOS: brew install gettext && brew link --force gettext" >&2
  exit 1
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${DOMAIN:?DOMAIN must be set (e.g. in .env or the environment)}"
: "${PANGOLIN_SECRET:?PANGOLIN_SECRET must be set (e.g. in .env or the environment)}"

export DOMAIN PANGOLIN_SECRET
envsubst '$DOMAIN $PANGOLIN_SECRET' < config/config.template.yml > config/config.yml

docker compose up -d "$@"
