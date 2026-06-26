#!/usr/bin/env bash
# Log Cursor agent token usage to a Vikunja ticket comment and local rollup file.
#
# Usage:
#   log-usage.sh --hook                         # read sessionEnd hook JSON on stdin
#   log-usage.sh HL-10 52000 9800 [model] [session_id]
#   log-usage.sh --identifier HL-10 --input 52000 --output 9800 [--model M] [--session S] [--cwd DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ROLLUP_FILE="${VIKUNJA_USAGE_ROLLUP:-${HOME}/.cursor/vikunja-usage.json}"

IDENTIFIER=""
INPUT_TOKENS=""
OUTPUT_TOKENS=""
MODEL=""
SESSION_ID=""
CWD=""

usage() {
  echo "Usage: $0 --hook" >&2
  echo "       $0 <identifier> <input_tokens> <output_tokens> [model] [session_id]" >&2
  echo "       $0 --identifier HL-N --input N --output N [--model M] [--session S] [--cwd DIR]" >&2
  exit 1
}

parse_hook_payload() {
  local payload="$1"

  CWD=$(echo "$payload" | jq -r '.cwd // .workspace.current_dir // empty')
  SESSION_ID=$(echo "$payload" | jq -r '.session_id // empty')
  MODEL=$(echo "$payload" | jq -r '.model.display_name // .model.id // empty')

  INPUT_TOKENS=$(echo "$payload" | jq -r '
    .context_window.total_input_tokens
    // .context_window.current_usage.input_tokens
    // .context_window.current_usage.input
    // empty
  ')
  OUTPUT_TOKENS=$(echo "$payload" | jq -r '
    .context_window.total_output_tokens
    // .context_window.current_usage.output_tokens
    // .context_window.current_usage.output
    // empty
  ')

  if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
    IDENTIFIER="$(vikunja_identifier_from_branch "$(git -C "$CWD" branch --show-current 2>/dev/null || true)")"
  fi
}

parse_args() {
  if [ "${1:-}" = "--hook" ]; then
    local payload
    payload="$(cat)"
    [ -n "$payload" ] || exit 0
    parse_hook_payload "$payload"
    return
  fi

  if [ $# -ge 3 ] && [[ "${1:-}" =~ ^(HL|ME)-[0-9]+$ ]]; then
    IDENTIFIER="$1"
    INPUT_TOKENS="$2"
    OUTPUT_TOKENS="$3"
    MODEL="${4:-}"
    SESSION_ID="${5:-}"
    return
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --identifier) IDENTIFIER="$2"; shift 2 ;;
      --input) INPUT_TOKENS="$2"; shift 2 ;;
      --output) OUTPUT_TOKENS="$2"; shift 2 ;;
      --model) MODEL="$2"; shift 2 ;;
      --session) SESSION_ID="$2"; shift 2 ;;
      --cwd) CWD="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
}

should_skip() {
  if [ -z "$IDENTIFIER" ]; then
    echo "No HL-/ME- ticket found — skipping token log"
    return 0
  fi

  if { [ -z "$INPUT_TOKENS" ] || [ "$INPUT_TOKENS" = "null" ]; } \
    && { [ -z "$OUTPUT_TOKENS" ] || [ "$OUTPUT_TOKENS" = "null" ]; }; then
    echo "No token counts in payload — skipping token log for ${IDENTIFIER}"
    return 0
  fi

  return 1
}

update_rollup() {
  local now_utc session_entry totals sessions

  mkdir -p "$(dirname "$ROLLUP_FILE")"
  [ -f "$ROLLUP_FILE" ] || echo '{}' > "$ROLLUP_FILE"

  now_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  session_entry=$(jq -n \
    --arg session_id "${SESSION_ID:-unknown}" \
    --arg model "${MODEL:-unknown}" \
    --arg at "$now_utc" \
    --arg input "${INPUT_TOKENS:-0}" \
    --arg output "${OUTPUT_TOKENS:-0}" \
    '{
      session_id: $session_id,
      model: $model,
      input: (($input | if . == "" or . == "null" then 0 else . end) | tonumber),
      output: (($output | if . == "" or . == "null" then 0 else . end) | tonumber),
      at: $at
    }')

  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
    if jq -e --arg id "$SESSION_ID" \
      --arg ident "$IDENTIFIER" \
      '.[$ident].sessions[]? | select(.session_id == $id)' \
      "$ROLLUP_FILE" >/dev/null 2>&1; then
      echo "Session ${SESSION_ID} already logged for ${IDENTIFIER} — skipping"
      exit 0
    fi
  fi

  jq --arg ident "$IDENTIFIER" --argjson entry "$session_entry" '
    .[$ident] //= {sessions: [], total_input: 0, total_output: 0}
    | .[$ident].sessions += [$entry]
    | .[$ident].total_input = ([.[$ident].sessions[].input] | add // 0)
    | .[$ident].total_output = ([.[$ident].sessions[].output] | add // 0)
  ' "$ROLLUP_FILE" > "${ROLLUP_FILE}.tmp" && mv "${ROLLUP_FILE}.tmp" "$ROLLUP_FILE"

  totals=$(jq -r --arg ident "$IDENTIFIER" \
    '.[$ident] | "\(.total_input) \(.total_output) \(.sessions | length)"' \
    "$ROLLUP_FILE")
  read -r TOTAL_INPUT TOTAL_OUTPUT SESSION_COUNT <<< "$totals"
}

post_comment() {
  local task_id
  local input_fmt output_fmt total_in_fmt total_out_fmt
  local comment session_line model_line

  vikunja_load_credentials

  if ! task_id="$(vikunja_lookup_task_id "$IDENTIFIER")"; then
    echo "::warning::Could not resolve Vikunja task for ${IDENTIFIER}"
    exit 0
  fi

  input_fmt="$(vikunja_format_token_count "$INPUT_TOKENS")"
  output_fmt="$(vikunja_format_token_count "$OUTPUT_TOKENS")"
  total_in_fmt="$(vikunja_format_token_count "${TOTAL_INPUT:-0}")"
  total_out_fmt="$(vikunja_format_token_count "${TOTAL_OUTPUT:-0}")"

  session_line=""
  [ -n "$SESSION_ID" ] && session_line=" (session \`${SESSION_ID}\`)"
  model_line=""
  [ -n "$MODEL" ] && model_line=$'\n'"- Model: ${MODEL}"

  comment=$(cat <<EOF
**Agent usage**${session_line}
- Input: ${input_fmt}
- Output: ${output_fmt}${model_line}
- **Ticket total:** ${total_in_fmt} in / ${total_out_fmt} out (${SESSION_COUNT} session(s))
EOF
)

  vikunja_add_comment "$task_id" "$comment"
  echo "Logged token usage on ${IDENTIFIER} (task ${task_id})"
}

main() {
  parse_args "$@"

  if should_skip; then
    exit 0
  fi

  update_rollup
  post_comment
}

main "$@"
