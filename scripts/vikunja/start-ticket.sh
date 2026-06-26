#!/usr/bin/env bash
# Mark a Vikunja ticket as in progress when starting work.
# Sets start_date (if unset) and moves the task to the Doing/In Progress kanban bucket.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  echo "Usage: $0 <task_id>" >&2
  exit 1
fi

vikunja_load_credentials

TASK_JSON=$(curl -sf \
  -H "$(vikunja_auth_header)" \
  -H "Content-Type: application/json" \
  "${VIKUNJA_API_URL}/tasks/${TASK_ID}")

IDENTIFIER=$(echo "$TASK_JSON" | jq -r '.identifier // empty')
PROJECT_ID=$(echo "$TASK_JSON" | jq -r '.project_id')
START_DATE=$(echo "$TASK_JSON" | jq -r '.start_date // empty')
DONE=$(echo "$TASK_JSON" | jq -r '.done // false')

if [ "$DONE" = "true" ]; then
  echo "Task ${IDENTIFIER:-$TASK_ID} is already done — skipping"
  exit 0
fi

if vikunja_date_unset "$START_DATE"; then
  NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  UPDATED_TASK=$(echo "$TASK_JSON" | jq --arg start_date "$NOW_UTC" '.start_date = $start_date')
  curl -sf \
    -X POST \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    -d "$UPDATED_TASK" \
    "${VIKUNJA_API_URL}/tasks/${TASK_ID}" >/dev/null
  echo "Set start_date on ${IDENTIFIER:-$TASK_ID} to ${NOW_UTC}"
else
  echo "start_date already set on ${IDENTIFIER:-$TASK_ID} — leaving unchanged"
fi

vikunja_move_task_to_bucket "$TASK_ID" "$PROJECT_ID" "doing" "${IDENTIFIER:-$TASK_ID}"
