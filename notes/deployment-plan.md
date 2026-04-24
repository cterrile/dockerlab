# Automated Stack Deployment Plan

GitOps + Ansible deployment system for the dockerlab homelab infrastructure.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        GitHub Repo                          │
│                    (dockerlab, main branch)                  │
└──────────┬──────────────────────────────────┬───────────────┘
           │ push / merge                     │
           ▼                                  ▼
┌─────────────────────┐          ┌────────────────────────────┐
│  GitHub Actions CI   │          │   GitHub Actions CI        │
│  (hosted runner)     │          │   (self-hosted runner)     │
│                      │          │   on: artemis (home net)   │
│  • lint compose      │          │                            │
│  • validate infra.yml│          │  • pull secrets from       │
│  • dry-run checks    │          │    Infisical               │
│                      │          │  • run ansible-playbook    │
│                      │          │    targeting all hosts      │
└──────────────────────┘          └─────────┬──────────────────┘
                                            │
                          ┌─────────────────┼──────────────────┐
                          │ SSH             │ local             │ SSH
                          ▼                 ▼                   ▼
                   ┌────────────┐   ┌────────────┐   ┌────────────────┐
                   │  VPS Host  │   │  artemis   │   │  Future Host   │
                   │ (DO droplet│   │ (home net) │   │  (DO / other)  │
                   │  "hermes") │   │            │   │                │
                   └────────────┘   └────────────┘   └────────────────┘
```

**Key constraint:** The home network machine (artemis) cannot receive inbound SSH, but _can_ SSH out to all VPS hosts. This makes it the natural Ansible control node — run via a self-hosted GitHub Actions runner.

---

## 1. Repository Structure Changes

Add deployment infrastructure alongside existing stacks:

```
dockerlab/
├── .github/
│   └── workflows/
│       ├── deploy.yml              # main deployment workflow
│       └── validate.yml            # PR validation (lint, dry-run)
│
├── ansible/
│   ├── ansible.cfg                 # ansible configuration
│   ├── inventory/
│   │   ├── hosts.yml               # host inventory (non-secret connection info)
│   │   └── group_vars/
│   │       ├── all.yml             # shared variables
│   │       └── vps.yml             # VPS-specific variables
│   ├── playbooks/
│   │   ├── deploy-stacks.yml       # main deployment playbook
│   │   ├── deploy-gateway.yml      # gateway-specific deployment
│   │   └── setup-host.yml          # one-time host bootstrap
│   ├── roles/
│   │   └── docker_stack/
│   │       ├── tasks/
│   │       │   └── main.yml        # deploy a single compose stack
│   │       ├── handlers/
│   │       │   └── main.yml
│   │       └── templates/
│   │           └── env.j2          # .env template for stacks
│   └── filter_plugins/
│       └── infra_filters.py        # custom filter to parse infra.yml
│
├── scripts/
│   └── resolve-changed-stacks.sh   # detect which stacks changed in a commit
│
├── gateway/                        # (existing)
├── stacks/                         # (existing)
│   ├── glance/
│   │   ├── docker-compose.yml
│   │   └── infra.yml               # ← expanded metadata (see below)
│   ├── mealie/
│   └── uptime/
└── README.md
```

---

## 2. Expand `infra.yml` Metadata

The existing `infra.yml` convention is a great foundation. Expand it to carry everything Ansible needs to deploy a stack.

```yaml
# stacks/glance/infra.yml
host: artemis
deploy_path: /opt/stacks/glance        # where the stack lives on the target host
env_file: true                          # whether to render a .env from secrets
secrets:                                # Infisical secret keys to inject as env vars
  - GLANCE_SECRET_KEY
docker_volumes:
  glance_data:
    backup: false
depends_on_stacks: []                   # optional cross-stack ordering
```

Each stack's `infra.yml` becomes the single source of truth for _where_ and _how_ it deploys. Ansible reads these at runtime.

---

## 3. Ansible Inventory & Configuration

### `ansible/inventory/hosts.yml`

```yaml
all:
  children:
    home:
      hosts:
        artemis:
          ansible_connection: local     # runner IS this machine
    vps:
      hosts:
        hermes:
          ansible_host: <ip-or-hostname>
          ansible_user: deploy
          ansible_ssh_private_key_file: ~/.ssh/id_ed25519
        # future hosts added here
```

### `ansible/ansible.cfg`

```ini
[defaults]
inventory = inventory/hosts.yml
roles_path = roles
host_key_checking = False
retry_files_enabled = False

[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
```

---

## 4. Ansible Playbook & Role

### `ansible/playbooks/deploy-stacks.yml`

The main playbook discovers stacks, groups them by host, and deploys.

```yaml
- name: Deploy Docker Compose stacks
  hosts: all
  become: true
  vars:
    stacks_dir: "{{ playbook_dir }}/../../stacks"
    changed_stacks: "{{ lookup('env', 'CHANGED_STACKS') | default('all', true) }}"

  pre_tasks:
    - name: Discover stacks assigned to this host
      set_fact:
        my_stacks: >-
          {{
            lookup('fileglob', stacks_dir ~ '/*/infra.yml')
            | map('regex_replace', '.*/([^/]+)/infra.yml', '\\1')
            | select('in_host', inventory_hostname)
            | list
          }}

    - name: Filter to changed stacks only (if not deploying all)
      set_fact:
        deploy_stacks: >-
          {{
            my_stacks if changed_stacks == 'all'
            else my_stacks | intersect(changed_stacks.split(','))
          }}

  roles:
    - role: docker_stack
      loop: "{{ deploy_stacks }}"
      loop_var: stack_name
```

### `ansible/roles/docker_stack/tasks/main.yml`

```yaml
- name: Load stack infra config
  include_vars:
    file: "{{ stacks_dir }}/{{ stack_name }}/infra.yml"
    name: stack_infra

- name: Ensure deploy directory exists
  file:
    path: "{{ stack_infra.deploy_path }}"
    state: directory
    mode: "0750"

- name: Sync stack files to host
  synchronize:
    src: "{{ stacks_dir }}/{{ stack_name }}/"
    dest: "{{ stack_infra.deploy_path }}/"
    delete: true
    rsync_opts:
      - "--exclude=infra.yml"
  notify: restart stack

- name: Render .env from secrets
  template:
    src: env.j2
    dest: "{{ stack_infra.deploy_path }}/.env"
    mode: "0600"
  when: stack_infra.env_file | default(false)
  notify: restart stack

- name: Deploy stack
  community.docker.docker_compose_v2:
    project_src: "{{ stack_infra.deploy_path }}"
    state: present
    pull: always
    remove_orphans: true
```

---

## 5. Secrets Management with Infisical

### Flow

```
Infisical Cloud/Self-hosted
         │
         │  CLI fetch (infisical export)
         ▼
GitHub Actions Runner (artemis)
         │
         │  env vars / ansible vars
         ▼
Ansible renders .env files per stack
```

### Integration Points

1. **GitHub Actions** — Use the [Infisical GitHub Action](https://github.com/Infisical/infisical-action) or the Infisical CLI to pull secrets at the start of the workflow and export them as environment variables.

2. **Ansible** — Secrets arrive as env vars on the runner. The `env.j2` template maps them to each stack's `.env` file based on the `secrets` list in `infra.yml`.

3. **Infisical project structure** — Organize secrets by environment/folder:
   ```
   Infisical Project: dockerlab
   ├── /shared            # secrets used by multiple stacks
   ├── /gateway           # DOMAIN, PANGOLIN_SECRET, etc.
   ├── /glance
   ├── /mealie
   └── /uptime
   ```

### `ansible/roles/docker_stack/templates/env.j2`

```jinja2
# Auto-generated — do not edit manually
{% for secret_key in stack_infra.secrets | default([]) %}
{{ secret_key }}={{ lookup('env', secret_key) }}
{% endfor %}
```

---

## 6. GitHub Actions Workflows

### `.github/workflows/deploy.yml`

```yaml
name: Deploy Stacks

on:
  push:
    branches: [main]
    paths:
      - 'stacks/**'
      - 'gateway/**'
      - 'ansible/**'

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      changed_stacks: ${{ steps.changes.outputs.stacks }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Detect changed stacks
        id: changes
        run: |
          CHANGED=$(git diff --name-only HEAD~1 HEAD -- stacks/ \
            | cut -d'/' -f2 | sort -u | paste -sd,)
          echo "stacks=${CHANGED:-all}" >> "$GITHUB_OUTPUT"

  deploy:
    needs: detect-changes
    runs-on: self-hosted               # artemis
    environment: production
    steps:
      - uses: actions/checkout@v4

      - name: Fetch secrets from Infisical
        uses: Infisical/secrets-action@v1
        with:
          url: ${{ secrets.INFISICAL_URL }}
          client-id: ${{ secrets.INFISICAL_CLIENT_ID }}
          client-secret: ${{ secrets.INFISICAL_CLIENT_SECRET }}
          project-id: ${{ secrets.INFISICAL_PROJECT_ID }}
          env-slug: prod

      - name: Run Ansible deployment
        working-directory: ansible
        env:
          CHANGED_STACKS: ${{ needs.detect-changes.outputs.changed_stacks }}
        run: |
          ansible-playbook playbooks/deploy-stacks.yml \
            --limit "$(echo $CHANGED_STACKS | tr ',' '\n' \
              | xargs -I{} grep -l 'host:' ../stacks/{}/infra.yml \
              | xargs -I{} awk '/^host:/{print $2}' {} | sort -u | paste -sd,)"
```

### `.github/workflows/validate.yml`

```yaml
name: Validate

on:
  pull_request:
    paths:
      - 'stacks/**'
      - 'gateway/**'
      - 'ansible/**'

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Validate docker-compose files
        run: |
          for f in stacks/*/docker-compose.yml; do
            echo "Checking $f..."
            docker compose -f "$f" config --quiet
          done

      - name: Validate infra.yml schemas
        run: |
          for f in stacks/*/infra.yml; do
            python3 -c "
          import yaml, sys
          with open('$f') as fh:
              data = yaml.safe_load(fh)
          assert 'host' in data, f'Missing host in $f'
          assert 'deploy_path' in data, f'Missing deploy_path in $f'
          print(f'  ✓ $f')
          "
          done

      - name: Ansible lint
        run: |
          pip install ansible-lint
          cd ansible && ansible-lint playbooks/
```

---

## 7. Adding a New Host

When a new machine joins the fleet:

1. **Add to inventory** — New entry under `vps:` (or `home:`) in `ansible/inventory/hosts.yml`
2. **Bootstrap** — Run `ansible-playbook playbooks/setup-host.yml --limit new-host` to install Docker, create deploy user, sync SSH keys
3. **Assign stacks** — Set `host: new-host` in the relevant `infra.yml` files
4. **Push** — Merge to main; the pipeline deploys only the affected stacks

### `ansible/playbooks/setup-host.yml`

Bootstraps a fresh host with Docker, docker compose plugin, deploy user, and firewall rules. Run once per new machine.

---

## 8. Adding a New Stack

1. Create `stacks/<name>/docker-compose.yml`
2. Create `stacks/<name>/infra.yml` with target host and deploy path
3. Add secrets to Infisical under `/<name>/` if needed
4. Push to main — pipeline picks it up automatically

No Ansible changes required. The playbook dynamically discovers stacks from the filesystem.

---

## 9. Implementation Phases

### Phase 1: Foundation
- [ ] Set up self-hosted GitHub Actions runner on artemis
- [ ] Install Ansible on artemis
- [ ] Create `ansible/` directory structure, inventory, and config
- [ ] Write the `docker_stack` role with basic sync + compose up
- [ ] Manually test: `ansible-playbook deploy-stacks.yml` from artemis

### Phase 2: Secrets
- [ ] Stand up Infisical (self-hosted or cloud)
- [ ] Migrate existing `.env` / hardcoded secrets into Infisical
- [ ] Add Infisical CLI or GitHub Action to the workflow
- [ ] Implement `env.j2` template rendering in the Ansible role
- [ ] Audit repo for any committed secrets (consul encrypt key, etc.)

### Phase 3: CI/CD Pipeline
- [ ] Create `.github/workflows/validate.yml` for PR checks
- [ ] Create `.github/workflows/deploy.yml` for main branch deploys
- [ ] Implement changed-stack detection (only deploy what changed)
- [ ] Test end-to-end: push to main → runner picks up → Ansible deploys

### Phase 4: Expand `infra.yml`
- [ ] Standardize all existing stacks with expanded `infra.yml`
- [ ] Migrate legacy top-level stacks (`gateway/`, `vaultwarden/`, etc.) into `stacks/`
- [ ] Add deploy paths, secret references, and volume backup metadata

### Phase 5: Hardening
- [ ] Add deployment notifications (GitHub, Discord, etc.)
- [ ] Add rollback mechanism (git revert → redeploy, or keep previous compose state)
- [ ] Add health checks post-deploy (curl endpoints, container status)
- [ ] Document the `setup-host.yml` bootstrap playbook
- [ ] Set up log aggregation for deploy runs

---

## 10. Security Considerations

| Concern | Mitigation |
|---------|------------|
| Secrets in repo | All secrets live in Infisical; `.env` files are `.gitignore`d and rendered at deploy time |
| SSH key management | Deploy keys stored as GitHub Actions secrets; rotated periodically |
| Runner exposure | Self-hosted runner on home network; not internet-accessible |
| Consul encrypt key | Currently committed (`central-host/consul-server/server.json`); migrate to Infisical and rotate |
| Least privilege | Ansible uses a dedicated `deploy` user on VPS hosts, not root (become via sudo) |

---

## 11. Design Decisions & Rationale

**Why Ansible over plain shell scripts?**
Idempotency, inventory management, and role reuse. Adding a host or stack requires no script changes — just config.

**Why self-hosted runner as the control node?**
Artemis can reach all hosts (local + VPS via SSH) but can't be reached from outside. Running the Ansible control node here avoids exposing SSH keys or VPN tunnels in CI.

**Why `infra.yml` per stack?**
Keeps deployment metadata colocated with the stack it describes. Ansible discovers stacks dynamically — no central manifest to maintain.

**Why Infisical over Vault/SOPS?**
Simpler operational model for a homelab. CLI and GitHub Action support. Self-hostable if you want it on your own infra later.

**Why deploy only changed stacks?**
Faster deploys, less risk. Full deploys available by setting `CHANGED_STACKS=all`.
