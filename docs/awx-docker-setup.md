# AWX in Docker (No Kubernetes, No Minikube)

End-to-end instructions for running AWX locally using plain Docker and
Docker Compose — no Kubernetes cluster or Minikube required.

> **Note:** The official AWX project now recommends the Operator on Kubernetes
> for production. The Docker Compose approach covered here is best suited for
> local testing, development, and homelab use.

---

## Prerequisites

- Ubuntu 22.04 / 24.04 (or any Linux host with Docker)
- At least 4 GB RAM and 2 CPU cores free
- Docker and Docker Compose installed (steps below)
- `git`, `make` available

---

## Part 1 — Install Docker

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Add your user to the `docker` group so you don't need `sudo` for every command:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker version
docker compose version
```

---

## Part 2 — Set Up the AWX Docker Compose Project

AWX requires four services running together:

| Service | Purpose |
|---|---|
| `postgres` | AWX database |
| `redis` | Message broker / cache between web and task worker |
| `awx_web` | Django web application (the UI + API) |
| `awx_task` | Ansible task runner (executes playbooks) |

### 2.1 Create the project directory

```bash
mkdir -p ~/awx-docker && cd ~/awx-docker
```

### 2.2 Create the secret key file

AWX uses a secret key to encrypt sensitive data. Generate one and keep it:

```bash
echo "$(openssl rand -base64 30)" > secret_key
chmod 600 secret_key
cat secret_key   # note it down somewhere safe
```

### 2.3 Create `docker-compose.yml`

```bash
cat > docker-compose.yml << 'EOF'
version: "3.8"

x-awx-env: &awx-env
  SECRET_KEY_FILE: /etc/tower/SECRET_KEY
  DATABASE_HOST: postgres
  DATABASE_NAME: awx
  DATABASE_USER: awx
  DATABASE_PASSWORD: awxdbpass
  REDIS_HOST: redis
  AWX_ADMIN_USER: admin
  AWX_ADMIN_PASSWORD: adminpass   # change this

services:

  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_USER: awx
      POSTGRES_PASSWORD: awxdbpass
      POSTGRES_DB: awx
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U awx"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7
    restart: unless-stopped
    volumes:
      - redis_data:/data

  awx_web:
    image: ansible/awx:24.6.1    # check https://hub.docker.com/r/ansible/awx/tags
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    ports:
      - "8080:8052"
    environment:
      <<: *awx-env
    volumes:
      - ./secret_key:/etc/tower/SECRET_KEY:ro
      - awx_projects:/var/lib/awx/projects
    command: /usr/bin/launch_awx.sh

  awx_task:
    image: ansible/awx:24.6.1
    restart: unless-stopped
    depends_on:
      - awx_web
    environment:
      <<: *awx-env
      SUPERVISOR_WEB_CONFIG_PATH: /etc/supervisord.conf
    volumes:
      - ./secret_key:/etc/tower/SECRET_KEY:ro
      - awx_projects:/var/lib/awx/projects
    command: /usr/bin/launch_awx_task.sh
    hostname: awx_task

volumes:
  postgres_data:
  redis_data:
  awx_projects:
EOF
```

> **Change `adminpass`** to a strong password before starting.
> **Pin the image tag** to a specific version rather than `latest` so upgrades
> are intentional. Check https://hub.docker.com/r/ansible/awx/tags for current releases.

### 2.4 Start AWX

```bash
docker compose up -d
```

Watch the logs while AWX initialises (takes 2–5 minutes on first start):

```bash
docker compose logs -f awx_web
```

Wait until you see a line like:
```
... supervisord started with pid 1
... awx-uwsgi entered RUNNING state
```

### 2.5 Open the UI

Navigate to: **http://localhost:8080**

Login with:
- **Username:** `admin`
- **Password:** the value you set for `AWX_ADMIN_PASSWORD` in `docker-compose.yml`

---

## Part 3 — Configure AWX for this Project

### 3.1 Add a Vault Credential

This is the password you used (or will use) to encrypt your `vault.yml` files.

1. Left sidebar → **Credentials** → **Add**
2. Fill in:
   - **Name**: `OKD Vault Password`
   - **Credential Type**: `Vault`
   - **Vault Password**: paste your vault password
3. Click **Save**

### 3.2 Add a Source Control Credential (SSH key for GitHub)

1. Left sidebar → **Credentials** → **Add**
2. Fill in:
   - **Name**: `GitHub SSH`
   - **Credential Type**: `Source Control`
   - **SSH Private Key**: paste the contents of your `~/.ssh/id_ed25519`
3. Click **Save**

### 3.3 Add a Project

1. Left sidebar → **Projects** → **Add**
2. Fill in:
   - **Name**: `okd-clean-cluster-shutdown`
   - **SCM Type**: `Git`
   - **SCM URL**: `git@github.com:<youruser>/okd-clean-cluster-shutdown.git`
   - **SCM Branch**: `main`
   - **SCM Credential**: `GitHub SSH`
   - **Update Revision on Launch**: ✓
3. Click **Save**

AWX clones the repo into `/var/lib/awx/projects` inside the container.
The status indicator turns green when the sync succeeds.

### 3.4 Add Inventories — one per cluster

Repeat for `okd-prod`, `okd-staging`, etc.:

1. Left sidebar → **Inventories** → **Add → Add inventory**
2. **Name**: `okd-prod` → **Save**
3. **Sources** tab → **Add**
   - **Name**: `okd-prod source`
   - **Source**: `Sourced from a Project`
   - **Project**: `okd-clean-cluster-shutdown`
   - **Inventory File**: `inventories/okd-prod/hosts.yml`
4. **Save** → click the sync icon

AWX picks up `group_vars/` from the same directory automatically, so all
cluster-specific variables (VM names, vCenter, paths) are available to the playbook.

### 3.5 Add Job Templates

Repeat for each operation and cluster:

1. Left sidebar → **Templates** → **Add → Add job template**
2. Fill in:
   - **Name**: `OKD Prod — Shutdown`
   - **Job Type**: `Run`
   - **Inventory**: `okd-prod`
   - **Project**: `okd-clean-cluster-shutdown`
   - **Playbook**: `shutdown.yml`
   - **Credentials**: search → filter by type **Vault** → select `OKD Vault Password`
3. Click **Save**

Recommended set of templates:

| Template Name | Playbook | Inventory |
|---|---|---|
| OKD Prod — Shutdown | `shutdown.yml` | okd-prod |
| OKD Prod — Startup | `startup.yml` | okd-prod |
| OKD Staging — Shutdown | `shutdown.yml` | okd-staging |
| OKD Staging — Startup | `startup.yml` | okd-staging |

### 3.6 (Optional) Workflow Template — ordered multi-cluster shutdown

1. Left sidebar → **Templates** → **Add → Add workflow template**
2. **Name**: `OKD Full Shutdown` → **Save**
3. Click **Visualizer**
4. **+** → **Run** → `OKD Staging — Shutdown` → **Save**
5. Click the node → **+** → **On Success** → `OKD Prod — Shutdown` → **Save**
6. **Save** in the visualizer

### 3.7 (Optional) Schedule a template

1. Open any Job Template → **Schedules** tab → **Add**
2. Set a name and cron rule (e.g. `0 22 * * 1-5` = weekdays at 22:00)
3. Click **Save**

---

## Part 4 — Managing the AWX Container

### Everyday commands

```bash
cd ~/awx-docker

# Start
docker compose up -d

# Stop (keeps data)
docker compose stop

# Restart
docker compose restart

# See running containers
docker compose ps

# Live logs
docker compose logs -f

# Logs for one service
docker compose logs -f awx_web
docker compose logs -f awx_task
```

### Update AWX to a newer version

1. Edit `docker-compose.yml` and change the image tag for both `awx_web` and `awx_task`
2. Pull and restart:

```bash
docker compose pull
docker compose up -d
```

### Destroy completely (deletes all data)

```bash
docker compose down -v
```

---

## Part 5 — Caveats and Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| UI shows 502 / not reachable | `awx_web` still starting | Wait 2–3 min; `docker compose logs awx_web` |
| Project sync fails | SSH key not added, or wrong repo URL | Check **Credentials** and the project SCM URL |
| Playbook can't reach vCenter | Container network / DNS | Check `vcenter_hostname` resolves from inside the container: `docker compose exec awx_task ping <vcenter_hostname>` |
| Playbook can't reach OKD API | Same network issue or wrong kubeconfig path | Ensure kubeconfig path inside the container matches `kubeconfig_path` in `group_vars/all.yml` |
| `pyvmomi` not found | Python lib missing in AWX image | Add an execution environment or install in task container: `docker compose exec awx_task pip3 install pyvmomi` |
| Vault decrypt fails | Wrong vault password in AWX credential | Re-create the Vault credential with the correct password |

### Checking the AWX task worker

```bash
# Open a shell inside the task container
docker compose exec awx_task bash

# Check Ansible and collections are available
ansible --version
ansible-galaxy collection list

# Install missing Python deps inside the container (temporary — lost on restart)
pip3 install pyvmomi jmespath
```

> For a permanent fix, build a custom Execution Environment image with
> `pyvmomi` and `jmespath` pre-installed, or add an `awx_ee` override in
> `docker-compose.yml`.
