#!/usr/bin/env bash
# Record worker completion when a PR is opened (does not mark the ticket done).
# Sets end_date (if unset) and comments with the PR URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TASK_ID="${1:-}"
PR_URL="${2:-}"

if [ -z "$TASK_ID" ] || [ -z "$PR_URL" ]; then
  echo "Usage: $0 <task_id> <pr_url>" >&2
  exit 1
fi

vikunja_load_credentials

TASK_JSON=$(curl -sf \
  -H "$(vikunja_auth_header)" \
  -H "Content-Type: application/json" \
  "${VIKUNJA_API_URL}/tasks/${TASK_ID}")

IDENTIFIER=$(echo "$TASK_JSON" | jq -r '.identifier // empty')
END_DATE=$(echo "$TASK_JSON" | jq -r '.end_date // empty')
DONE=$(echo "$TASK_JSON" | jq -r '.done // false')

if [ "$DONE" = "true" ]; then
  echo "Task ${IDENTIFIER:-$TASK_ID} is already done — skipping"
  exit 0
fi

if vikunja_date_unset "$END_DATE"; then
  NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  UPDATED_TASK=$(echo "$TASK_JSON" | jq --arg end_date "$NOW_UTC" '.end_date = $end_date')
  curl -sf \
    -X POST \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    -d "$UPDATED_TASK" \
    "${VIKUNJA_API_URL}/tasks/${TASK_ID}" >/dev/null
  echo "Set end_date on ${IDENTIFIER:-$TASK_ID} to ${NOW_UTC}"
else
  echo "end_date already set on ${IDENTIFIER:-$TASK_ID} — leaving unchanged"
fi

vikunja_add_comment "$TASK_ID" "PR opened: ${PR_URL}"
echo "Commented on ${IDENTIFIER:-$TASK_ID} with PR link"
