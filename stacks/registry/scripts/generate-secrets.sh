#!/usr/bin/env bash
# Runbook: generate the two Infisical secrets for the registry stack.
#
# Run this on your own machine (requires Docker for the bcrypt htpasswd step).
# It prints the two secret values to set in Infisical, plus the plaintext
# admin password to store in your password manager. It does NOT call the
# Infisical CLI — paste the printed values into the Infisical UI yourself
# (prod env, project f217186f-b64f-4e05-ac49-2af700a2cc5c).
#
#   REGISTRY_HTTP_SECRET  — random; the registry uses it for signed state.
#   REGISTRY_HTPASSWD     — base64-encoded htpasswd file (single line, so it
#                           survives the .env single-line format). The stack's
#                           registry-init container decodes it at startup.
#
# Account created: admin (used for CLI, the UI basic-auth prompt, and CI).
# We intentionally start with a single account to keep auth debugging simple.
# To add more accounts later (e.g. separate CI service accounts), append
# additional `htpasswd -Bbn <user> <pw>` lines and re-base64 the file.
#
# Re-running regenerates EVERYTHING (new secret + new password). To rotate
# only the admin password while keeping the HTTP secret, leave
# REGISTRY_HTTP_SECRET alone and only re-set REGISTRY_HTPASSWD.
set -euo pipefail

need() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }
need openssl
need docker

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# bcrypt htpasswd via the httpd image (macOS has no htpasswd). The password is
# passed as container env, not a host cmdline arg.
#
# The password is generated from a pure alphanumeric alphabet (A-Za-z0-9) —
# no '/', '+', or '=' — so it survives copy/paste, shells, URLs, and Infisical
# fields without escaping issues.
rand_pw() { openssl rand 48 | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }

HTTP_SECRET="$(openssl rand -hex 32)"
ADMIN_PW="$(rand_pw)"

# NOTE: pass each password with -e VAR="$VAR" (explicit value), NOT -e VAR.
# `VAR="$(rand_pw)"` creates a non-exported shell variable, so `docker run -e VAR`
# (no value) has nothing to inherit and would pass an EMPTY password — the hash
# would silently be built for "" while the script prints the real password, and
# the self-verify (also empty) would falsely report "verified".
docker run --rm \
  -v "$WORK:/work" \
  -e ADMIN_PW="$ADMIN_PW" \
  --entrypoint sh httpd:2.4 -c '
    htpasswd -Bbn admin "$ADMIN_PW" >> /work/htpasswd
  '

HTPASSWD_B64="$(base64 < "$WORK/htpasswd" | tr -d '\n')"

# Self-verify: confirm the generated password actually authenticates against
# the htpasswd we just built. If the line below says FAILED, the script itself
# is broken — do not use the output.
docker run --rm \
  -v "$WORK:/work" \
  -e ADMIN_PW="$ADMIN_PW" \
  --entrypoint sh httpd:2.4 -c '
    if htpasswd -vb /work/htpasswd admin "$ADMIN_PW" >/dev/null 2>&1; then
      echo "admin: verified"
    else
      echo "admin: FAILED"
    fi
  '

cat <<EOF

=== Set these in Infisical (prod) ===
REGISTRY_HTTP_SECRET=${HTTP_SECRET}
REGISTRY_HTPASSWD=${HTPASSWD_B64}

=== Account password — store in your password manager ===
admin = ${ADMIN_PW}
EOF
