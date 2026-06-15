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
