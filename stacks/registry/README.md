# registry

Private Docker registry (CNCF Distribution `registry:2`) with a Joxit browse/delete UI, fronted by Pangolin.

## Services

| Service | Purpose | Exposed at | Auth |
|---------|---------|------------|------|
| `registry` | `registry:2` API (push/pull) | `registry.${DOMAIN}` | htpasswd basic auth (no Pangolin SSO) |
| `registry-ui` | Joxit browse/delete UI | `registry-ui.${DOMAIN}` | Pangolin SSO + registry basic-auth prompt |
| `registry-init` | one-shot; writes `htpasswd` from the `REGISTRY_HTPASSWD` secret | — | — |

The registry API deliberately has **no Pangolin SSO** because `docker login`/push/pull use HTTP Basic auth, which can't go through a browser OIDC redirect. The UI uses Pangolin SSO to gate human access, then proxies `/v2/` to the registry via `NGINX_PROXY_PASS_URL` (same-origin from the browser, so no CORS config is needed on the registry). The browser will prompt for HTTP Basic auth on the first `/v2/` call and cache it.

## Secrets (Infisical → `.env`)

Set these in Infisical prod for this stack (listed in `infra.yml`):

- `DOMAIN` — base domain (shared).
- `REGISTRY_HTPASSWD` — full htpasswd file content (bcrypt), multiline. See below.
- `REGISTRY_HTTP_SECRET` — random string used by the registry for signed state.

The plaintext passwords for each account are **not** stored by this stack — keep them in Infisical separately (e.g. `REGISTRY_PASSWORD_<ACCOUNT>`) so you can look them up to log in or hand to CI.

## Generating / rotating the htpasswd

Run `scripts/generate-secrets.sh` from this stack directory (requires local Docker). It prints the two Infisical secret values to set, plus the plaintext account passwords to store in your password manager — it does **not** call the Infisical CLI, so paste the printed `REGISTRY_HTTP_SECRET` and `REGISTRY_HTPASSWD` into the Infisical UI (prod env) yourself.

The `registry-init` container base64-decodes `REGISTRY_HTPASSWD` back into `/auth/htpasswd` on every `compose up`, so rotation is: re-run the script (or edit one account's line in the htpasswd) → update the Infisical secret → deploy.

Initial accounts: `admin` (CLI/ops), `ui` (UI browser login), `ci-jenkins`, `ci-github`.

## CI usage

```bash
docker login registry.${DOMAIN} -u ci-jenkins   # Jenkins: cred sourced from Infisical
# GitHub Actions: REGISTRY_USERNAME / REGISTRY_PASSWORD repo secrets = ci-github account
docker build -t registry.${DOMAIN}/<repo>/<image>:<sha> .
docker push    registry.${DOMAIN}/<repo>/<image>:<sha>
```

`registry.${DOMAIN}` is public via Pangolin/Gerbil with Let's Encrypt TLS, so pushes from GitHub Actions work over HTTPS with no `--insecure-registry`.

## Garbage collection

Deleting an image (from the UI or API) only removes the manifest reference; the blobs remain. `stacks/dagu/dags/garbage-collect-registry.yaml` runs `registry garbage-collect --delete-untagged` weekly (Sun 03:00). Caveat: GC while concurrent pushes happen can be lossy — the weekly 03:00 window is low-traffic; for stricter safety, stop the registry before GC and restart it after.

## Auth model & limitations

- htpasswd has **no per-repo RBAC** — any valid account can push/pull/delete anywhere. We get independent credentials + rotation, not access isolation. If per-repo ACLs are ever needed, swap htpasswd for `cesanta/docker_auth` (single container, ACLs in a committed YAML file, scoped tokens, same htpasswd backend).
- The `ui` account is separate from `admin` so the browser-cached cred can be rotated independently of the CLI admin cred.
- Trust model: anyone who passes Pangolin SSO can reach the UI and then use a registry account. Only trusted users should be in Pangolin SSO for this domain.

## Future: S3 storage

Storage is currently filesystem on the `registry-data` named volume (backed up). When an S3-compatible stack exists, switch by setting `REGISTRY_STORAGE_*` env vars on the `registry` service (e.g. `REGISTRY_STORAGE=s3`, `REGISTRY_STORAGE_S3_BUCKET`, `REGISTRY_STORAGE_S3_REGION`, `REGISTRY_STORAGE_S3_ACCESSKEY`, `REGISTRY_STORAGE_S3_SECRETKEY`, `REGISTRY_STORAGE_S3_REGIONENDPOINT`) and removing the `registry-data` volume mount. Migrate existing blobs out of band (or start fresh). No compose structural change needed.
