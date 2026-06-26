# Shared helpers for Vikunja scripts. Source from other scripts in this directory.
vikunja_load_credentials() {
  if [ -z "${VIKUNJA_API_TOKEN:-}" ] && [ -f "${HOME}/.cursor/mcp.json" ]; then
    VIKUNJA_API_TOKEN="$(jq -r '.mcpServers.vikunja.env.VIKUNJA_API_TOKEN // empty' "${HOME}/.cursor/mcp.json")"
    VIKUNJA_API_URL="$(jq -r '.mcpServers.vikunja.env.VIKUNJA_URL // empty' "${HOME}/.cursor/mcp.json")"
  fi

  : "${VIKUNJA_API_URL:?VIKUNJA_API_URL is required}"
  : "${VIKUNJA_API_TOKEN:?VIKUNJA_API_TOKEN is required}"
}

vikunja_auth_header() {
  printf 'Authorization: Bearer %s' "$VIKUNJA_API_TOKEN"
}

vikunja_add_comment() {
  local task_id="$1"
  local comment="$2"
  curl -sf \
    -X PUT \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg comment "$comment" '{comment: $comment}')" \
    "${VIKUNJA_API_URL}/tasks/${task_id}/comments" >/dev/null
}

vikunja_date_unset() {
  [[ "${1:-}" == "0001-01-01"* || -z "${1:-}" ]]
}

vikunja_kanban_view_for_project() {
  case "$1" in
    3) echo 12 ;; # HL
    1) echo 4 ;;  # ME
    *) echo "" ;;
  esac
}

vikunja_bucket_fallback_id() {
  local project_id="$1"
  local bucket_kind="$2"
  case "${project_id}:${bucket_kind}" in
    3:doing) echo 8 ;;
    3:for_review) echo 13 ;;
    1:doing) echo 2 ;;
    # ME For Review: add column in Vikunja, probe bucket id, then set 1:for_review)
    *) echo "" ;;
  esac
}

vikunja_buckets_list_failed() {
  local buckets_json="$1"
  echo "$buckets_json" | jq -e 'type == "object" and (.message != null or .code != null)' >/dev/null 2>&1
}

vikunja_find_bucket_id() {
  local buckets_json="$1"
  local bucket_kind="$2"
  local project_id="$3"
  local jq_filter
  local bucket_id

  case "$bucket_kind" in
    doing)
      jq_filter='[.[] | select(
        (.title | ascii_downcase) == "doing"
        or (.title | ascii_downcase) == "in progress"
        or (.title | ascii_downcase | test("in[ -]?progress"))
        or (.title | ascii_downcase | test("^doing"))
      )] | first | .id // empty'
      ;;
    for_review)
      jq_filter='[.[] | select(
        (.title | ascii_downcase) == "for review"
        or (.title | ascii_downcase | test("for[ -]?review"))
        or (.title | ascii_downcase) == "review"
        or (.title | ascii_downcase | test("^in[ -]?review"))
      )] | first | .id // empty'
      ;;
    *)
      echo "::warning::Unknown bucket kind ${bucket_kind}" >&2
      return 1
      ;;
  esac

  bucket_id=$(echo "$buckets_json" | jq -r "
    if type == \"object\" and .message then empty else
      ${jq_filter}
    end
  ")

  if { [ -z "$bucket_id" ] || [ "$bucket_id" = "null" ]; } \
    && vikunja_buckets_list_failed "$buckets_json"; then
    bucket_id="$(vikunja_bucket_fallback_id "$project_id" "$bucket_kind")"
    if [ -n "$bucket_id" ]; then
      echo "Buckets list unavailable — using fallback ${bucket_kind} bucket id ${bucket_id} for project ${project_id}" >&2
    fi
  fi

  if [ -z "$bucket_id" ] || [ "$bucket_id" = "null" ]; then
    bucket_id="$(vikunja_bucket_fallback_id "$project_id" "$bucket_kind")"
    if [ -n "$bucket_id" ]; then
      echo "Using fallback ${bucket_kind} bucket id ${bucket_id} for project ${project_id}" >&2
    fi
  fi

  if [ -z "$bucket_id" ] || [ "$bucket_id" = "null" ]; then
    return 1
  fi

  echo "$bucket_id"
}

vikunja_move_task_to_bucket() {
  local task_id="$1"
  local project_id="$2"
  local bucket_kind="$3"
  local identifier="${4:-$task_id}"
  local view_id
  local buckets_json
  local bucket_id
  local bucket_title

  view_id="$(vikunja_kanban_view_for_project "$project_id")"
  if [ -z "$view_id" ]; then
    echo "::warning::No kanban view configured for project ${project_id} — skipped bucket move"
    return 0
  fi

  buckets_json=$(curl -sS \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    "${VIKUNJA_API_URL}/projects/${project_id}/views/${view_id}/buckets") || {
    echo "::warning::Could not list buckets for project ${project_id} view ${view_id} — skipped bucket move"
    return 0
  }

  if ! bucket_id="$(vikunja_find_bucket_id "$buckets_json" "$bucket_kind" "$project_id")"; then
    echo "::warning::No ${bucket_kind} bucket found for project ${project_id} view ${view_id} — skipped bucket move (add kanban column and set fallback id in vikunja_bucket_fallback_id)"
    return 0
  fi

  if curl -sS \
    -X POST \
    -H "$(vikunja_auth_header)" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --argjson task_id "$task_id" '{task_id: $task_id}')" \
    "${VIKUNJA_API_URL}/projects/${project_id}/views/${view_id}/buckets/${bucket_id}/tasks" >/dev/null; then
    bucket_title=$(echo "$buckets_json" | jq -r --argjson id "$bucket_id" '
      if type == "array" then
        (.[] | select(.id == $id) | .title) // empty
      else
        empty
      end
    ')
    echo "Moved ${identifier} to bucket: ${bucket_title:-${bucket_kind}}"
  else
    echo "::warning::Failed to move ${identifier} to ${bucket_kind} bucket ${bucket_id}"
  fi
}
