# AWX (Minikube) + NUT/upsmon Setup Guide

End-to-end instructions for:
1. Running AWX locally in Minikube (for testing / homelab)
2. Connecting this project to AWX
3. Setting up NUT/upsmon on the Ubuntu management VM to trigger the shutdown automatically on a UPS power event

---

## Part 1 — AWX on Minikube

### Prerequisites

A Linux host or WSL2 (Ubuntu) with:
- Docker installed and running
- At least 4 CPU cores and 6 GB of RAM available
- `curl`, `git` available

### 1.1 Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

### 1.2 Install Minikube

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64
minikube version
```

### 1.3 Install Kustomize

```bash
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
kustomize version
```

### 1.4 Start Minikube

```bash
minikube start --cpus=4 --memory=6g --driver=docker
```

Verify it started:

```bash
kubectl get nodes
# Expected: minikube   Ready   ...
```

### 1.5 Install AWX Operator

Set the version once (check https://github.com/ansible/awx-operator/releases for the latest):

```bash
export AWX_OPERATOR_VERSION=2.19.1
```

Create the `awx` namespace and install the operator:

```bash
kubectl create namespace awx
kubectl apply -k "https://github.com/ansible/awx-operator/config/default?ref=${AWX_OPERATOR_VERSION}"
```

Wait for the operator pod to be ready (takes ~1 minute):

```bash
kubectl -n awx wait --for=condition=Ready pod \
  -l control-plane=controller-manager \
  --timeout=120s
```

### 1.6 Create the AWX Instance

```bash
mkdir -p ~/awx-local && cd ~/awx-local

cat > awx.yaml <<EOF
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx-local
  namespace: awx
spec:
  service_type: nodeport
EOF

cat > kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - github.com/ansible/awx-operator/config/default?ref=${AWX_OPERATOR_VERSION}
  - awx.yaml

namespace: awx

images:
  - name: quay.io/ansible/awx-operator
    newTag: ${AWX_OPERATOR_VERSION}
EOF

kubectl apply -k .
```

Watch the pods come up (takes 5–10 minutes on first run):

```bash
kubectl -n awx get pods -w
```

Wait until you see both `awx-local-web-*` and `awx-local-task-*` in `Running` state.

### 1.7 Get the Admin Password

```bash
kubectl -n awx get secret awx-local-admin-password \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Username is always `admin`.

### 1.8 Open the AWX UI

```bash
minikube service awx-local-service -n awx --url
```

Open the printed URL (e.g. `http://192.168.49.2:30080`) in your browser and log in with `admin` and the password from step 1.7.

### 1.9 Stopping / Restarting AWX

```bash
# Stop without deleting
minikube stop

# Start again
minikube start

# Destroy completely
minikube delete
```

---

## Part 2 — Configure AWX for this Project

### 2.1 Add a Credential — Vault password

This is the password you encrypted your `vault.yml` files with. AWX passes it to Ansible automatically so the playbook can decrypt secrets.

1. Left sidebar → **Credentials** → **Add**
2. Fill in:
   - **Name**: `OKD Vault Password`
   - **Credential Type**: `Vault`
   - **Vault Password**: paste your vault password string
3. Click **Save**

> If you haven't encrypted your vault files yet, pick any strong password now, write it down, then run:
> ```bash
> ansible-vault encrypt inventories/okd-prod/group_vars/vault.yml
> ansible-vault encrypt inventories/okd-staging/group_vars/vault.yml
> ```

### 2.2 Add a Project — Git repository

1. Left sidebar → **Projects** → **Add**
2. Fill in:
   - **Name**: `okd-clean-cluster-shutdown`
   - **SCM Type**: `Git`
   - **SCM URL**: `git@github.com:<youruser>/okd-clean-cluster-shutdown.git`
   - **SCM Branch**: `main`
   - **Update Revision on Launch**: ✓ (checked)
   - **Credential**: your GitHub SSH credential (add one under Credentials → type: Source Control if needed)
3. Click **Save**

AWX will immediately sync and clone the repo. The status dot turns green when done.

### 2.3 Add Inventories — one per cluster

Repeat these steps for each cluster (`okd-prod`, `okd-staging`, etc.):

1. Left sidebar → **Inventories** → **Add → Add inventory**
2. Fill in:
   - **Name**: `okd-prod`
3. Click **Save**
4. Click the **Sources** tab → **Add**
5. Fill in:
   - **Name**: `okd-prod source`
   - **Source**: `Sourced from a Project`
   - **Project**: `okd-clean-cluster-shutdown`
   - **Inventory File**: `inventories/okd-prod/hosts.yml`
6. Click **Save**, then click the sync icon to pull the inventory

AWX automatically picks up the `group_vars/` directory alongside `hosts.yml`, so all cluster-specific variables (VM names, vCenter, timeouts) are available to the playbook.

### 2.4 Add Job Templates

Repeat for each combination. Steps for `OKD Prod — Shutdown`:

1. Left sidebar → **Templates** → **Add → Add job template**
2. Fill in:
   - **Name**: `OKD Prod — Shutdown`
   - **Job Type**: `Run`
   - **Inventory**: `okd-prod`
   - **Project**: `okd-clean-cluster-shutdown`
   - **Playbook**: `shutdown.yml`
   - **Credentials**: click search → filter by type **Vault** → select `OKD Vault Password`
3. Click **Save**

Recommended set of templates:

| Template Name | Playbook | Inventory |
|---|---|---|
| OKD Prod — Shutdown | `shutdown.yml` | okd-prod |
| OKD Prod — Startup | `startup.yml` | okd-prod |
| OKD Staging — Shutdown | `shutdown.yml` | okd-staging |
| OKD Staging — Startup | `startup.yml` | okd-staging |

### 2.5 (Optional) Add a Workflow Template — multi-cluster ordered shutdown

A Workflow Template chains job templates in sequence with failure handling.

1. Left sidebar → **Templates** → **Add → Add workflow template**
2. **Name**: `OKD Full Shutdown`
3. Click **Save**, then click **Visualizer**
4. Click the **+** node → **Run** → select `OKD Staging — Shutdown` → **Save**
5. Click the green node → **+** → **On Success** → select `OKD Prod — Shutdown` → **Save**
6. Click **Save** in the visualizer

This shuts down staging first, then production only if staging succeeded.

### 2.6 (Optional) Schedule a Job Template

1. Open any Job Template → **Schedules** tab → **Add**
2. Set name, start date, and a cron rule (e.g. `0 22 * * 1-5` = weekdays at 22:00)
3. Click **Save**

---

## Part 3 — NUT / upsmon Setup on the Ubuntu Management VM

NUT (Network UPS Tools) monitors the UPS and calls `scripts/trigger-shutdown.sh` when the battery reaches a critical level, which in turn runs `ansible-playbook shutdown.yml`.

### 3.1 Install NUT

```bash
sudo apt update
sudo apt install -y nut
```

### 3.2 Determine your UPS connection type

| UPS type | Driver to use | `port` value |
|---|---|---|
| USB-attached to this VM | `usbhid-ups` | `auto` |
| Network UPS with SNMP card | `snmp-ups` | IP or hostname of UPS |
| APC with network card (proprietary) | `apcsmart` or `apc_modbus` | IP or serial device |

> **VMware note:** ESXi does not automatically forward USB to guests. Options:
> - Configure USB passthrough for this VM in the vSphere UI (_Edit Settings → Add device → USB device_)
> - Use a network-capable UPS (SNMP) — no passthrough needed
> - Run `upsd` on a physical host that has USB access and point `upsmon` on the management VM at `myups@<that-host>`

### 3.3 Configure NUT — five files

#### `/etc/nut/nut.conf`

```
MODE=standalone
```

Use `standalone` when `upsd` and `upsmon` both run on this VM.
Use `netclient` if `upsd` is on another machine.

#### `/etc/nut/ups.conf`

**USB-attached:**
```
[myups]
    driver = usbhid-ups
    port   = auto
    desc   = "UPS attached via USB"
```

**SNMP/network:**
```
[myups]
    driver    = snmp-ups
    port      = 192.0.2.10     # IP of UPS management interface
    community = public
    version   = 2
    desc      = "UPS via SNMP"
```

#### `/etc/nut/upsd.conf`

```
LISTEN 127.0.0.1 3493
```

#### `/etc/nut/upsd.users`

```
[upsmon_user]
    password  = secret_password
    actions   = SET
    instcmds  = ALL
```

Replace `secret_password` with a strong password. This is only used for communication between `upsmon` and `upsd` on localhost — it is not the Ansible Vault password.

#### `/etc/nut/upsmon.conf`

```
# Replace myups@localhost with myups@<host> if upsd is on another machine
MONITOR myups@localhost 1 upsmon_user secret_password master

SHUTDOWNCMD "/opt/okd-shutdown/scripts/trigger-shutdown.sh"

NOTIFYFLAG ONLINE   SYSLOG+EXEC
NOTIFYFLAG ONBATT   SYSLOG+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+EXEC
NOTIFYFLAG FSD      SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC

# Ignore power blips shorter than 30 seconds
DEADTIME 30

# Poll upsd every 5 seconds (2 seconds when on-battery)
POLLFREQ      5
POLLFREQALERT 2

# Set to 0 so the playbook controls all timing before shutdown
FINALDELAY 0
```

### 3.4 Deploy this project to the management VM

```bash
sudo mkdir -p /opt/okd-shutdown
sudo git clone https://github.com/<youruser>/okd-clean-cluster-shutdown.git /opt/okd-shutdown
sudo chmod +x /opt/okd-shutdown/scripts/trigger-shutdown.sh
sudo mkdir -p /opt/okd-shutdown/logs

# Store the Ansible Vault password
echo 'your-vault-password' | sudo tee /opt/okd-shutdown/.vault_pass > /dev/null
sudo chmod 600 /opt/okd-shutdown/.vault_pass
```

### 3.5 Enable and start NUT services

```bash
sudo systemctl enable --now nut-server nut-monitor
```

### 3.6 Verify the UPS is visible

```bash
upsc myups@localhost
```

You should see a list including `ups.status: OL` (on-line). If this command fails, check `/var/log/syslog` or:

```bash
sudo journalctl -u nut-server -u nut-monitor -f
```

Common issues:

| Symptom | Fix |
|---|---|
| `upsc` returns "can't connect" | Check `upsd` is running: `systemctl status nut-server` |
| Driver fails to start | Check USB passthrough is configured in vSphere, or switch to SNMP |
| `Data stale` in `ups.status` | Driver not communicating with UPS — wrong port or driver |

### 3.7 Test end-to-end without cutting power

Run the trigger script manually — this executes the full Ansible shutdown playbook against your configured inventory:

```bash
sudo /opt/okd-shutdown/scripts/trigger-shutdown.sh
```

Watch the log:

```bash
tail -f /opt/okd-shutdown/logs/nut-trigger-*.log
```

### 3.8 How the full event flow works

```
UPS battery drops to critical / FSD
    │
    ▼
upsd detects status change (via USB/SNMP polling every 5s)
    │
    ▼
upsmon reads new status from upsd
    │
    ▼
upsmon executes SHUTDOWNCMD
    │
    ▼
/opt/okd-shutdown/scripts/trigger-shutdown.sh
    │
    ├── acquires lock (/tmp/okd-shutdown.lock)
    ├── ansible-playbook shutdown.yml
    │       ├── role: backup    (etcd snapshot)
    │       ├── role: drain     (cordon + evict worker pods)
    │       └── role: vm_shutdown (workers off → CPs off, one by one)
    │
    └── (optional) /sbin/shutdown -h now   ← management VM powers off last
```
