#!/usr/bin/env bash
# Mark a Vikunja ticket as in progress when starting work.
# Sets start_date (if unset) and moves the task to the Doing/In Progress kanban bucket.
set -euo pipefail

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  echo "Usage: $0 <task_id>" >&2
  exit 1
fi

if [ -z "${VIKUNJA_API_TOKEN:-}" ] && [ -f "${HOME}/.cursor/mcp.json" ]; then
  VIKUNJA_API_TOKEN="$(jq -r '.mcpServers.vikunja.env.VIKUNJA_API_TOKEN // empty' "${HOME}/.cursor/mcp.json")"
  VIKUNJA_API_URL="$(jq -r '.mcpServers.vikunja.env.VIKUNJA_URL // empty' "${HOME}/.cursor/mcp.json")"
fi

: "${VIKUNJA_API_URL:?VIKUNJA_API_URL is required}"
: "${VIKUNJA_API_TOKEN:?VIKUNJA_API_TOKEN is required}"

auth_header() {
  printf 'Authorization: Bearer %s' "$VIKUNJA_API_TOKEN"
}

# Kanban view id per project (Homelab / Personal).
kanban_view_for_project() {
  case "$1" in
    3) echo 12 ;; # HL
    1) echo 4 ;;  # ME
    *) echo "" ;;
  esac
}

# Fallback Doing bucket id when title lookup fails (between default and done).
doing_bucket_fallback() {
  case "$1" in
    3) echo 8 ;;  # HL: default=7, done=9
    1) echo 2 ;;  # ME: default=1, done=3
    *) echo "" ;;
  esac
}

TASK_JSON=$(curl -sf \
  -H "$(auth_header)" \
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

if [[ "$START_DATE" == "0001-01-01"* || -z "$START_DATE" ]]; then
  NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  UPDATED_TASK=$(echo "$TASK_JSON" | jq --arg start_date "$NOW_UTC" '.start_date = $start_date')
  curl -sf \
    -X POST \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "$UPDATED_TASK" \
    "${VIKUNJA_API_URL}/tasks/${TASK_ID}" >/dev/null
  echo "Set start_date on ${IDENTIFIER:-$TASK_ID} to ${NOW_UTC}"
else
  echo "start_date already set on ${IDENTIFIER:-$TASK_ID} — leaving unchanged"
fi

VIEW_ID="$(kanban_view_for_project "$PROJECT_ID")"
if [ -z "$VIEW_ID" ]; then
  echo "::warning::No kanban view configured for project ${PROJECT_ID} — skipped bucket move"
  exit 0
fi

BUCKETS_JSON=$(curl -sS \
  -H "$(auth_header)" \
  -H "Content-Type: application/json" \
  "${VIKUNJA_API_URL}/projects/${PROJECT_ID}/views/${VIEW_ID}/buckets") || {
  echo "::warning::Could not list buckets for project ${PROJECT_ID} view ${VIEW_ID} — skipped bucket move"
  exit 0
}

DOING_BUCKET_ID=$(echo "$BUCKETS_JSON" | jq -r '
  if type == "object" and .message then empty else
    [.[] | select(
      (.title | ascii_downcase) == "doing"
      or (.title | ascii_downcase) == "in progress"
      or (.title | ascii_downcase | test("in[ -]?progress"))
      or (.title | ascii_downcase | test("^doing"))
    )] | first | .id // empty
  end
')

if [ -z "$DOING_BUCKET_ID" ] || [ "$DOING_BUCKET_ID" = "null" ]; then
  DOING_BUCKET_ID="$(doing_bucket_fallback "$PROJECT_ID")"
  if [ -n "$DOING_BUCKET_ID" ]; then
    echo "Using fallback Doing bucket id ${DOING_BUCKET_ID} for project ${PROJECT_ID}"
  fi
fi

if [ -z "$DOING_BUCKET_ID" ] || [ "$DOING_BUCKET_ID" = "null" ]; then
  echo "::warning::No Doing/In Progress bucket found for project ${PROJECT_ID} view ${VIEW_ID} — skipped bucket move"
  exit 0
fi

if curl -sS \
  -X POST \
  -H "$(auth_header)" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --argjson task_id "$TASK_ID" '{task_id: $task_id}')" \
  "${VIKUNJA_API_URL}/projects/${PROJECT_ID}/views/${VIEW_ID}/buckets/${DOING_BUCKET_ID}/tasks" >/dev/null; then
  BUCKET_TITLE=$(echo "$BUCKETS_JSON" | jq -r --argjson id "$DOING_BUCKET_ID" '
    if type == "array" then
      (.[] | select(.id == $id) | .title) // "Doing"
    else
      "Doing"
    end
  ')
  echo "Moved ${IDENTIFIER:-$TASK_ID} to bucket: ${BUCKET_TITLE}"
else
  echo "::warning::Failed to move ${IDENTIFIER:-$TASK_ID} to Doing bucket ${DOING_BUCKET_ID}"
fi
