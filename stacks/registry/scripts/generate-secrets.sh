#!/usr/bin/env bash
# Runbook: generate the two Infisical secrets for the registry stack.
#
# Run this on your own machine (requires Docker for the bcrypt htpasswd step).
# It prints the two secret values to set in Infisical, plus the plaintext
# account passwords to store in your password manager. It does NOT call the
# Infisical CLI — paste the printed values into the Infisical UI yourself
# (prod env, project f217186f-b64f-4e05-ac49-2af700a2cc5c).
#
#   REGISTRY_HTTP_SECRET  — random; the registry uses it for signed state.
#   REGISTRY_HTPASSWD     — base64-encoded htpasswd file (single line, so it
#                           survives the .env single-line format). The stack's
#                           registry-init container decodes it at startup.
#
# Accounts created: admin, ui, ci-jenkins, ci-github.
#   ui          — log into the UI (browser basic-auth prompt)
#   ci-jenkins  — Jenkins credential store
#   ci-github   — GitHub Actions repo secret (REGISTRY_USERNAME / REGISTRY_PASSWORD)
#   admin       — CLI / ops
#
# Re-running regenerates EVERYTHING (new secret + new passwords). To rotate a
# single account while keeping the others, keep the existing htpasswd lines and
# only regenerate that one account's line, then re-base64 and re-set the secret.
set -euo pipefail

need() { command -v "$1" >/dev/null || { echo "missing dependency: $1" >&2; exit 1; }; }
need openssl
need docker

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# bcrypt htpasswd via the httpd image (macOS has no htpasswd). Passwords are
# passed as container env, not host cmdline args.
#
# Passwords are generated from a pure alphanumeric alphabet (A-Za-z0-9) — no
# '/', '+', or '=' — so they survive copy/paste, shells, URLs, and Infisical
# fields without escaping issues.
rand_pw() { openssl rand 48 | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }

HTTP_SECRET="$(openssl rand -hex 32)"

ADMIN_PW="$(rand_pw)"
UI_PW="$(rand_pw)"
CI_JENKINS_PW="$(rand_pw)"
CI_GITHUB_PW="$(rand_pw)"
docker run --rm \
  -v "$WORK:/work" \
  -e ADMIN_PW -e UI_PW -e CI_JENKINS_PW -e CI_GITHUB_PW \
  --entrypoint sh httpd:2.4 -c '
    htpasswd -Bbn admin       "$ADMIN_PW"      >> /work/htpasswd
    htpasswd -Bbn ui          "$UI_PW"         >> /work/htpasswd
    htpasswd -Bbn ci-jenkins  "$CI_JENKINS_PW" >> /work/htpasswd
    htpasswd -Bbn ci-github   "$CI_GITHUB_PW"  >> /work/htpasswd
  '

HTPASSWD_B64="$(base64 < "$WORK/htpasswd" | tr -d '\n')"

cat <<EOF

=== Set these in Infisical (prod) ===
REGISTRY_HTTP_SECRET=${HTTP_SECRET}
REGISTRY_HTPASSWD=${HTPASSWD_B64}

=== Account passwords — store in your password manager ===
admin       = ${ADMIN_PW}
ui          = ${UI_PW}
ci-jenkins  = ${CI_JENKINS_PW}
ci-github   = ${CI_GITHUB_PW}
EOF
