#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <source_volume> <destination_volume>

Copy all contents from one Docker volume to another.
The destination volume will be created if it doesn't exist.

Options:
  -h, --help    Show this help message

Examples:
  $(basename "$0") myapp_data myapp_data_backup
  $(basename "$0") old_postgres_vol new_postgres_vol
EOF
  exit "${1:-0}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage 0
fi

if [[ $# -ne 2 ]]; then
  echo "Error: exactly 2 arguments required." >&2
  usage 1
fi

SRC_VOL="$1"
DST_VOL="$2"

if ! docker volume inspect "$SRC_VOL" &>/dev/null; then
  echo "Error: source volume '$SRC_VOL' does not exist." >&2
  exit 1
fi

if [[ "$SRC_VOL" == "$DST_VOL" ]]; then
  echo "Error: source and destination volumes must be different." >&2
  exit 1
fi

if ! docker volume inspect "$DST_VOL" &>/dev/null; then
  echo "Creating destination volume '$DST_VOL'..."
  docker volume create "$DST_VOL"
fi

echo "Copying '$SRC_VOL' -> '$DST_VOL'..."

docker run --rm \
  -v "${SRC_VOL}:/src:ro" \
  -v "${DST_VOL}:/dst" \
  alpine \
  sh -c 'cp -a /src/. /dst/'

echo "Done. Contents of '$SRC_VOL' have been copied to '$DST_VOL'."
