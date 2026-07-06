#!/usr/bin/env bash
# Print Infisical secrets required before deploying stacks/logging.
# Add under Infisical prod path /stacks/logging (or your stack infisical_path).
#
# Example (after logging stack is live, for VPS site agents under /sites/icarus and /sites/gaia):
#   LOG_HOST_NAME=icarus
#   LOKI_INGEST_URL=https://loki-ingest.${DOMAIN}/loki/api/v1/push
#   LOKI_INGEST_USER=<same as logging stack>
#   LOKI_INGEST_PASSWORD=<same as logging stack>
set -euo pipefail

cat <<'EOF'
Infisical prod — stacks/logging (/stacks/logging):
  DOMAIN                  (shared — likely already set)
  GRAFANA_ADMIN_PASSWORD  strong password for Grafana admin
  SEAWEEDFS_ACCESS_KEY    e.g. $(openssl rand -hex 16)
  SEAWEEDFS_SECRET_KEY    e.g. $(openssl rand -hex 32)
  LOKI_INGEST_USER        e.g. loki-agent
  LOKI_INGEST_PASSWORD    e.g. $(openssl rand -base64 24)

Infisical prod — site VPS hosts (/sites/icarus, /sites/gaia):
  LOG_HOST_NAME           hostname label (icarus or gaia)
  LOKI_INGEST_URL         https://loki-ingest.<domain>/loki/api/v1/push
  LOKI_INGEST_USER        must match logging stack
  LOKI_INGEST_PASSWORD    must match logging stack

Before first deploy on artemis:
  scripts/logging/create-volumes.sh

After daemon.json is applied:
  ansible-playbook playbooks/recreate-stacks.yml --limit artemis
EOF
