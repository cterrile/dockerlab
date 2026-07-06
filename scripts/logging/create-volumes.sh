#!/usr/bin/env bash
# Create external Docker volumes for the logging stack on artemis.
# Run once before the first deploy:
#   ssh deploy@artemis 'bash -s' < scripts/logging/create-volumes.sh
set -euo pipefail

VOLUMES=(
  logging-seaweedfs-master-data
  logging-seaweedfs-volume-data
  logging-loki-data
  logging-grafana-data
)

for vol in "${VOLUMES[@]}"; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "Volume exists: $vol"
  else
    docker volume create "$vol"
    echo "Created: $vol"
  fi
done

echo "Logging stack volumes ready."
