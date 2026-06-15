#!/usr/bin/env bash
# Mark Vikunja tickets done after a successful deploy.
# Extracts HL-XX / ME-XX identifiers from the deploy commit message.
set -euo pipefail

: "${VIKUNJA_API_URL:?VIKUNJA_API_URL is required}"
: "${VIKUNJA_API_TOKEN:?VIKUNJA_API_TOKEN is required}"

COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"
DEPLOYED_STACKS="${DEPLOYED_STACKS:-}"
DEPLOY_COMMIT="${DEPLOY_COMMIT:-}"
GITHUB_RUN_URL="${GITHUB_RUN_URL:-}"
CLOSE_REASON="${CLOSE_REASON:-deploy}"

auth_header() {
  printf 'Authorization: Bearer %s' "$VIKUNJA_API_TOKEN"
}

project_id_for_prefix() {
  case "$1" in
    HL) echo 3 ;;
    ME) echo 1 ;;
    *) echo "" ;;
  esac
}

lookup_task_id() {
  local identifier="$1"
  local expected_project="$2"
  local task_num="${identifier##*-}"
  local response
  local actual_identifier
  local actual_project
  local done

  response=$(curl -sf \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    "${VIKUNJA_API_URL}/tasks/${task_num}" 2>/dev/null) || {
    echo "::warning::Could not fetch Vikunja task ${task_num} for ${identifier}"
    return 1
  }

  actual_identifier=$(echo "$response" | jq -r '.identifier // empty')
  actual_project=$(echo "$response" | jq -r '.project_id // empty')
  done=$(echo "$response" | jq -r '.done // false')

  if [ "$actual_identifier" != "$identifier" ]; then
    echo "::warning::Task ${task_num} identifier mismatch: expected ${identifier}, got ${actual_identifier}"
    return 1
  fi

  if [ "$actual_project" != "$expected_project" ]; then
    echo "::warning::Task ${identifier} project mismatch: expected ${expected_project}, got ${actual_project}"
    return 1
  fi

  if [ "$done" = "true" ]; then
    echo "Task ${identifier} is already done — skipping"
    return 2
  fi

  echo "$task_num"
}

mark_task_done() {
  local task_id="$1"
  curl -sf \
    -X POST \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d '{"done": true}' \
    "${VIKUNJA_API_URL}/tasks/${task_id}" >/dev/null
}

add_task_comment() {
  local task_id="$1"
  local comment="$2"
  curl -sf \
    -X PUT \
    -H "$(auth_header)" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg comment "$comment" '{comment: $comment}')" \
    "${VIKUNJA_API_URL}/tasks/${task_id}/comments" >/dev/null
}

if [ -z "$COMMIT_MESSAGE" ]; then
  echo "No commit message available — skipping Vikunja ticket close"
  exit 0
fi

mapfile -t IDENTIFIERS < <(printf '%s\n' "$COMMIT_MESSAGE" | grep -oE '(HL|ME)-[0-9]+' | sort -u)

if [ "${#IDENTIFIERS[@]}" -eq 0 ]; then
  echo "No Vikunja ticket identifier found in commit message — skipping"
  exit 0
fi

COMMENT="Merged"
if [ "$CLOSE_REASON" = "deploy" ]; then
  COMMENT="Deployed"
fi
[ -n "$DEPLOY_COMMIT" ] && COMMENT+=" in commit \`${DEPLOY_COMMIT:0:7}\`"
[ -n "$DEPLOYED_STACKS" ] && COMMENT+=" — stacks: ${DEPLOYED_STACKS}"
[ -n "$GITHUB_RUN_URL" ] && COMMENT+=$'\n\n'"Workflow: ${GITHUB_RUN_URL}"

for identifier in "${IDENTIFIERS[@]}"; do
  prefix="${identifier%%-*}"
  project_id="$(project_id_for_prefix "$prefix")"

  if [ -z "$project_id" ]; then
    echo "::warning::Unknown ticket prefix in ${identifier} — skipping"
    continue
  fi

  if ! task_id="$(lookup_task_id "$identifier" "$project_id")"; then
    continue
  fi

  mark_task_done "$task_id"
  add_task_comment "$task_id" "$COMMENT"
  echo "Marked ${identifier} (task ${task_id}) as done"
done
