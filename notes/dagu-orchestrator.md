# Dagu Orchestrator

Lightweight DAG-based task runner replacing Jenkins/GitHub Actions self-hosted runner
for stack deployment and backup orchestration.

---

## Why Dagu

- Single ~20MB container, no database (flat file state)
- Pipelines are YAML files in the repo (`stacks/dagu/dags/`)
- Built-in cron scheduler for backup jobs
- Web UI with visual DAG graphs, run history, and real-time logs
- REST API for external triggers (GitHub webhooks)
- Docker socket support for local container management

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        GitHub Repo                          │
│                    (dockerlab, main branch)                  │
└──────────┬──────────────────────────────────┬───────────────┘
           │ pull request                     │ push to main
           ▼                                  ▼
┌─────────────────────┐          ┌────────────────────────────┐
│  GitHub Actions CI   │          │  GitHub Actions Deploy      │
│  (hosted runner)     │          │  (hosted runner)            │
│                      │          │                             │
│  • lint compose      │          │  • detect changed stacks    │
│  • validate infra.yml│          │  • resolve "all" → list     │
│  • ansible-lint      │          │  • single Dagu webhook with │
│                      │          │    comma-separated stacks   │
└──────────────────────┘          └─────────────┬──────────────┘
                                                │ single webhook
                                                ▼
                                  ┌────────────────────────────┐
                                  │   Dagu (on artemis)        │
                                  │   ops.${DOMAIN}            │
                                  │                            │
                                  │  • git pull                │
                                  │  • iterate stacks via      │
                                  │    parallel + sub-DAG      │
                                  │  • per stack:              │
                                  │    - resolve host          │
                                  │    - fetch secrets via     │
                                  │      Infisical CLI         │
                                  │    - run ansible-playbook  │
                                  │  • nightly DB backups      │
                                  └─────────────┬──────────────┘
                                                │
                          ┌─────────────────────┼──────────────────┐
                          │ SSH                 │ local             │ SSH
                          ▼                     ▼                   ▼
                   ┌────────────┐       ┌────────────┐   ┌────────────────┐
                   │  VPS Host  │       │  artemis   │   │  Future Host   │
                   │  "hermes"  │       │ (home net) │   │                │
                   └────────────┘       └────────────┘   └────────────────┘
```

---

## Secrets Flow

Only the Ansible control node (Dagu on artemis) needs Infisical access.
Remote hosts never talk to Infisical directly.

```
Infisical
    │
    │  infisical run --token $INFISICAL_TOKEN ... -- ansible-playbook ...
    │  (injects all secrets as env vars into the Ansible process)
    ▼
Dagu / artemis
    │
    │  Ansible renders .env per stack using env.j2 template:
    │    {% for secret_key in stack_infra.secrets %}
    │    {{ secret_key }}={{ lookup('env', secret_key) }}
    │    {% endfor %}
    │
    │  Template task writes .env to remote host (mode 0600)
    ▼
Remote host (e.g. hermes)
    │
    │  docker compose up -d
    │  (reads .env for variable interpolation)
    ▼
Running containers
```

**Key points:**

- `infisical run --token $INFISICAL_TOKEN` wraps the entire
  `ansible-playbook` command, exporting all project secrets as
  environment variables using token-based authentication
- Ansible's `lookup('env', ...)` reads those env vars on the control node
  (artemis), not on the remote host
- The `env.j2` template iterates over each stack's `secrets` list from
  `infra.yml` and renders a `.env` file
- That `.env` is pushed to the remote host via Ansible's `template` module
  over SSH
- Remote hosts only see the rendered `.env` with actual values — they have
  no awareness of Infisical

**What needs Infisical credentials:**

| Component | Needs Infisical? | Why |
|-----------|-----------------|-----|
| Dagu container | Yes | Runs `infisical run` to start deploys |
| Artemis (local) | Via Dagu only | Ansible runs inside the Dagu-spawned process |
| VPS hosts | No | Receive rendered `.env` files over SSH |

---

## DAG Pipelines

### deploy-stacks.yaml

Triggered by a single GitHub webhook or manual run from the Dagu UI.
Receives a `STACKS` parameter (comma-separated stack names).

**Parent DAG steps:**

| Step | Description |
|------|-------------|
| Pull latest | `git pull` the repo to pick up latest stack definitions |
| Build stack list | Convert comma-separated `STACKS` into a JSON array |
| Iterate | Call `deploy-stack` sub-DAG for each stack via `parallel` (sequential by default) |

**`deploy-stack` sub-DAG steps (runs once per stack):**

| Step | Description |
|------|-------------|
| Validate | Verify the stack directory exists |
| Resolve host | Look up the target Ansible host from `stacks/<STACK>/infra.yml` |
| Deploy | `infisical run --token ... -- ansible-playbook deploy-stacks.yml --limit $HOST` |

GitHub Actions detects changed stacks, resolves "all" to the concrete list,
and sends a single webhook with the comma-separated list. Dagu iterates
internally.

Manual trigger: pass `STACKS=glance` (or `STACKS=glance,mealie`) from the
Dagu UI.

### backup-postgres.yaml

Runs automatically at 3 AM daily via Dagu's built-in cron scheduler.

| Step | Description |
|------|-------------|
| `ensure_backup_dir` | Create backup directory if it doesn't exist |
| `backup_infisical` | `pg_dump` the Infisical database to a timestamped SQL file |
| `backup_mealie` | `pg_dump` the Mealie database to a timestamped SQL file |
| `prune_old` | Delete backups older than 30 days (configurable via `RETENTION_DAYS`) |

Each backup step has `continue_on: failure` so one failing database doesn't
block the others.

---

## Setup

### Env vars required

| Variable | Description |
|----------|-------------|
| `DOMAIN` | Base domain for Pangolin ingress (`ops.${DOMAIN}`) |
| `DAGU_ADMIN_USER` | Web UI login username |
| `DAGU_ADMIN_PASSWORD` | Web UI login password |
| `INFISICAL_API_URL` | Infisical instance URL |
| `INFISICAL_TOKEN` | Infisical service token for authentication |

### Container volume mounts

| Mount | Purpose |
|-------|---------|
| `./dags` → `/var/lib/dagu/dags` (ro) | DAG definitions from the repo |
| `docker.sock` | Backup jobs exec into Postgres containers |
| `~/.ssh` (ro) | Ansible SSH access to VPS hosts |
| `/home/deploy/dockerlab` | Repo checkout for deploy pipeline |
| `dagu-data` volume | Run history, logs, scheduler state |

### GitHub webhook

GitHub Actions sends a single webhook with all changed stacks:

```
POST https://ops.${DOMAIN}/api/v1/webhooks/deploy-stacks
Content-Type: application/json

{ "stacks": "glance,mealie", "commit": "<sha>", "ref": "refs/heads/main" }
```

The `stacks` field maps to the DAG's `STACKS` parameter (comma-separated).
Dagu iterates through the list internally using the `parallel` + `call`
pattern.
