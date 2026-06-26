#!/usr/bin/env bash
# Mark Vikunja tickets done after merge (and deploy when stacks change).
# Extracts HL-XX / ME-XX identifiers from the deploy commit message.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"
DEPLOYED_STACKS="${DEPLOYED_STACKS:-}"
DEPLOY_COMMIT="${DEPLOY_COMMIT:-}"
GITHUB_RUN_URL="${GITHUB_RUN_URL:-}"
CLOSE_REASON="${CLOSE_REASON:-deploy}"

vikunja_load_credentials

mark_task_done() {
  local task_id="$1"
  local task_json
  task_json=$(curl -sf \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    "${VIKUNJA_API_URL}/tasks/${task_id}")
  curl -sf \
    -X POST \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    -d "$(echo "$task_json" | jq '.done = true')" \
    "${VIKUNJA_API_URL}/tasks/${task_id}" >/dev/null
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
  if ! task_id="$(vikunja_lookup_task_id "$identifier")"; then
    echo "::warning::Could not resolve Vikunja task for ${identifier} — skipping"
    continue
  fi

  task_json=$(curl -sf \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    "${VIKUNJA_API_URL}/tasks/${task_id}")
  if [ "$(echo "$task_json" | jq -r '.done // false')" = "true" ]; then
    echo "Task ${identifier} is already done — skipping"
    continue
  fi

  mark_task_done "$task_id"
  vikunja_add_comment "$task_id" "$COMMENT"
  echo "Marked ${identifier} (task ${task_id}) as done"
done
