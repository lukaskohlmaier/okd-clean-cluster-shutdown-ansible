# OKD Clean Cluster Shutdown

Fully automated, production-grade Ansible project for **graceful shutdown and startup** of one or more OKD (OpenShift Kubernetes Distribution) clusters deployed via IPI on VMware vSphere.

Designed to be triggered automatically by a UPS power-loss event (via NUT), scheduled via **AWX / Ansible Tower**, or run manually from a management VM. Supports 1–n clusters, each with its own inventory, credentials, and timing configuration.

---

## Architecture

```
UPS power loss
      │
      ▼
NUT upsmon (management VM)
      │  SHUTDOWNCMD
      ▼
scripts/trigger-shutdown.sh
      │
      ▼
ansible-playbook shutdown.yml
      │
      ├─ role: backup       → oc adm cluster-backup (etcd snapshot)
      ├─ role: drain         → cordon + drain worker nodes
      └─ role: vm_shutdown   → power-off workers, then control-plane VMs
                               (quorum-aware, one-by-one)
```

Startup is the exact reverse:

```
ansible-playbook startup.yml
      │
      ├─ role: vm_startup    → power-on control-plane, then workers
      └─ role: healthcheck   → API, nodes, ClusterOperators, etcd
```

---

## Project Structure

```
okd-clean-cluster-shutdown/
├── ansible.cfg
├── requirements.yml
├── shutdown.yml                    # Main shutdown playbook
├── startup.yml                     # Main startup playbook
│
├── inventory/                      # Default / single-cluster inventory
│   ├── hosts.yml                   # Localhost inventory
│   └── group_vars/
│       ├── all.yml                 # All configurable variables
│       └── vault.yml               # vCenter credentials (encrypt this!)
│
├── inventories/                    # Multi-cluster inventories (1–n clusters)
│   ├── okd-prod/
│   │   ├── hosts.yml
│   │   └── group_vars/
│   │       ├── all.yml             # Production-specific config
│   │       └── vault.yml           # Production vCenter credentials
│   └── okd-staging/
│       ├── hosts.yml
│       └── group_vars/
│           ├── all.yml             # Staging-specific config
│           └── vault.yml           # Staging vCenter credentials
│
├── roles/
│   ├── backup/
│   │   ├── defaults/main.yml
│   │   └── tasks/main.yml          # etcd backup via oc adm cluster-backup
│   │
│   ├── drain/
│   │   ├── defaults/main.yml
│   │   └── tasks/main.yml          # Cordon + drain worker nodes
│   │
│   ├── vm_shutdown/
│   │   ├── defaults/main.yml
│   │   └── tasks/
│   │       ├── main.yml            # Orchestrate worker + CP shutdown
│   │       └── shutdown_single_cp.yml  # Quorum-aware single CP shutdown
│   │
│   ├── vm_startup/
│   │   ├── defaults/main.yml
│   │   └── tasks/main.yml          # Power-on CP first, then workers
│   │
│   └── healthcheck/
│       ├── defaults/main.yml
│       └── tasks/main.yml          # Post-startup cluster validation
│
├── scripts/
│   └── trigger-shutdown.sh         # NUT SHUTDOWNCMD entry point
│
├── nut/
│   └── upsmon.conf.example         # Example NUT configuration
│
├── tests/                          # Offline testing infrastructure
│   ├── run-tests.sh                # Test runner script
│   ├── mock-bin/                   # Mock oc + vmware scripts
│   │   └── oc                      # Stub that returns canned responses
│   └── test-inventory/             # Inventory with check_mode flags
│       ├── hosts.yml
│       └── group_vars/
│           └── all.yml             # Overrides for dry-run testing
│
└── logs/                           # Created at runtime (gitignored)
```

---

## Prerequisites

### Management VM

| Component | Purpose |
|---|---|
| Ansible >= 2.15 | Automation engine |
| `oc` CLI | Cluster operations (cluster-admin kubeconfig) |
| Python `pyvmomi` | VMware API access |
| NUT (`nut-client`) | UPS monitoring |

### Ansible Collections

```bash
ansible-galaxy collection install -r requirements.yml
```

This installs:
- `community.vmware` (>= 4.0.0)
- `kubernetes.core` (>= 3.0.0)
- `community.general` (>= 8.0.0)

### Python Dependencies

```bash
pip install pyvmomi jmespath
```

---

## Configuration

### Single Cluster

Edit `inventory/group_vars/all.yml` to match your environment:

```yaml
cluster_name: "okd-prod"
kubeconfig_path: "/home/ansible/.kube/config"
vcenter_hostname: "vcenter.example.com"
vcenter_datacenter: "DC1"

worker_vms:
  - "okd-worker-0"
  - "okd-worker-1"
  - "okd-worker-2"

control_plane_vms:
  - "okd-master-0"
  - "okd-master-1"
  - "okd-master-2"
```

### Multiple Clusters (1–n)

For environments with more than one cluster, use the `inventories/` directory. Each cluster gets its own sub-directory with a dedicated `hosts.yml`, `group_vars/all.yml`, and `group_vars/vault.yml`.

```
inventories/
├── okd-prod/
│   ├── hosts.yml
│   └── group_vars/
│       ├── all.yml          # Cluster-specific variables (VMs, timeouts, paths)
│       └── vault.yml        # vCenter credentials for this cluster
├── okd-staging/
│   ├── hosts.yml
│   └── group_vars/
│       ├── all.yml
│       └── vault.yml
└── okd-dev/                 # Add as many clusters as needed
    ├── hosts.yml
    └── group_vars/
        ├── all.yml
        └── vault.yml
```

**Adding a new cluster:**

1. Copy an existing cluster directory:
   ```bash
   cp -r inventories/okd-prod inventories/okd-new-cluster
   ```

2. Edit `inventories/okd-new-cluster/group_vars/all.yml` — set at minimum:
   - `cluster_name` — unique identifier
   - `kubeconfig_path` — path to this cluster's kubeconfig
   - `backup_dir` — unique backup directory for this cluster
   - `vcenter_hostname` / `vcenter_datacenter` — can point to a different vCenter
   - `worker_vms` / `control_plane_vms` — VM names in vSphere
   - Timing and retry values can be tuned per cluster (e.g., shorter delays for staging)

3. Edit `inventories/okd-new-cluster/group_vars/vault.yml` with the vCenter credentials for this cluster.

4. Encrypt the vault:
   ```bash
   ansible-vault encrypt inventories/okd-new-cluster/group_vars/vault.yml
   ```

Each cluster is fully isolated — different vCenters, datacenters, kubeconfigs, and timing profiles are all supported.

**Running against a specific cluster:**

```bash
# Shutdown production
ansible-playbook shutdown.yml -i inventories/okd-prod/hosts.yml --ask-vault-pass

# Shutdown staging
ansible-playbook shutdown.yml -i inventories/okd-staging/hosts.yml --ask-vault-pass

# Startup production
ansible-playbook startup.yml -i inventories/okd-prod/hosts.yml --ask-vault-pass
```

**Shutting down all clusters sequentially** (e.g., from a NUT trigger script):

```bash
for cluster in inventories/*/; do
  ansible-playbook shutdown.yml \
    -i "${cluster}hosts.yml" \
    --vault-password-file=~/.vault_pass
done
```

### 2. Encrypt vCenter Credentials

```bash
# Edit and encrypt the vault file
ansible-vault encrypt inventory/group_vars/vault.yml

# Or create from scratch
ansible-vault create inventory/group_vars/vault.yml
```

Required vault variables:

```yaml
vault_vcenter_username: "administrator@vsphere.local"
vault_vcenter_password: "your-password-here"
```

### 3. Verify KUBECONFIG

Ensure the management VM has a valid cluster-admin kubeconfig:

```bash
export KUBECONFIG=/home/ansible/.kube/config
oc cluster-info
oc get nodes
```

---

## Management VM Setup (Fresh Ubuntu VM)

This section covers the complete setup from a brand-new Ubuntu VM through to a fully wired, UPS-triggered shutdown automation.

### 1. Install System Packages

```bash
sudo apt update
sudo apt install -y \
    ansible \
    python3-pip \
    nut \
    git \
    curl
```

Then install Ansible collections and Python libraries required by the playbooks:

```bash
ansible-galaxy collection install -r /opt/okd-shutdown/requirements.yml
pip3 install pyvmomi jmespath
```

### 2. Install and Configure the `oc` CLI

```bash
# Download from the OKD/OpenShift mirror — replace the version as needed
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar xz
sudo mv oc /usr/local/bin/oc
oc version
```

Copy the cluster-admin kubeconfig from your OKD cluster to the management VM:

```bash
mkdir -p ~/.kube
# scp or paste kubeconfig content
scp core@<bastion>:/etc/kubernetes/admin.kubeconfig ~/.kube/config
chmod 600 ~/.kube/config
oc cluster-info
```

### 3. Deploy this Project

```bash
sudo mkdir -p /opt/okd-shutdown
sudo git clone https://github.com/<org>/okd-clean-cluster-shutdown.git /opt/okd-shutdown
sudo chmod +x /opt/okd-shutdown/scripts/trigger-shutdown.sh
sudo mkdir -p /opt/okd-shutdown/logs
```

Store the Ansible Vault password on disk — readable only by root:

```bash
echo 'your-vault-password' | sudo tee /opt/okd-shutdown/.vault_pass > /dev/null
sudo chmod 600 /opt/okd-shutdown/.vault_pass
```

### 4. Configure NUT (Network UPS Tools)

NUT has three components that each need a config file:

| File | Purpose |
|---|---|
| `/etc/nut/nut.conf` | Sets the NUT operating mode |
| `/etc/nut/ups.conf` | Defines the UPS and the driver used to talk to it |
| `/etc/nut/upsd.conf` | Controls where `upsd` listens |
| `/etc/nut/upsd.users` | Credentials that `upsmon` uses to authenticate to `upsd` |
| `/etc/nut/upsmon.conf` | Tells `upsmon` what to monitor and what commands to run |

#### 4a. `/etc/nut/nut.conf` — operating mode

```
MODE=standalone
```

Use `standalone` when the UPS is directly attached to this VM (USB or serial).
Use `netclient` if `upsd` runs on another host and this VM only monitors it.

#### 4b. `/etc/nut/ups.conf` — UPS driver

**Option A — USB-attached UPS** (UPS plugged into the VM via USB passthrough):

```
[myups]
    driver = usbhid-ups
    port   = auto
    desc   = "UPS attached via USB"
```

**Option B — Network/SNMP UPS** (UPS has a management card or network interface):

```
[myups]
    driver    = snmp-ups
    port      = 192.0.2.10     # IP or hostname of the UPS management interface
    community = public
    version   = 2
    desc      = "UPS via SNMP"
```

> **VMware note:** ESXi does not automatically pass host USB devices into guests. You must either configure USB passthrough for the VM in vSphere, use a network-capable UPS (SNMP), or run `upsd` on a machine that has direct USB access and point this VM's `upsmon` at `myups@<that-host>`.

#### 4c. `/etc/nut/upsd.conf` — listener

```
LISTEN 127.0.0.1 3493
```

#### 4d. `/etc/nut/upsd.users` — credentials

```
[upsmon_user]
    password  = secret_password
    actions   = SET
    instcmds  = ALL
```

#### 4e. `/etc/nut/upsmon.conf` — monitoring and shutdown hook

```
# Replace myups@localhost with myups@<upsd-host> if upsd is on another machine
MONITOR myups@localhost 1 upsmon_user secret_password master

SHUTDOWNCMD "/opt/okd-shutdown/scripts/trigger-shutdown.sh"

NOTIFYFLAG ONLINE   SYSLOG+EXEC
NOTIFYFLAG ONBATT   SYSLOG+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+EXEC
NOTIFYFLAG FSD      SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC

# Ignore micro-outages shorter than 30 seconds
DEADTIME 30

# How often upsmon polls upsd (seconds)
POLLFREQ      5
POLLFREQALERT 2

# Delay before forcing power-off — set to 0 so the playbook controls timing
FINALDELAY 0
```

### 5. Start and Enable NUT Services

```bash
sudo systemctl enable --now nut-server nut-monitor
```

Verify the UPS is visible:

```bash
upsc myups@localhost
```

You should see a list of values including `ups.status: OL` (on-line) or `ups.status: OB` (on-battery).

### 6. Verify the End-to-End Wiring

```bash
# Check upsd is listening
ss -tlnp | grep 3493

# Check upsmon is connected and monitoring
sudo systemctl status nut-monitor

# Tail NUT logs
sudo journalctl -u nut-server -u nut-monitor -f

# Manually test the trigger script (safe — runs the playbook, does not cut power)
sudo /opt/okd-shutdown/scripts/trigger-shutdown.sh

# Inspect the output log
ls -lh /opt/okd-shutdown/logs/
tail -f /opt/okd-shutdown/logs/nut-trigger-*.log
```

A successful end-to-end flow looks like:

```
upsmon detects FSD / LOWBATT
  → upsmon calls SHUTDOWNCMD → trigger-shutdown.sh
    → ansible-playbook shutdown.yml runs:
        backup → drain → vm_shutdown (workers, then CPs)
    → (optional) management VM powers off last
```

---

## Usage

### Graceful Shutdown (Manual)

```bash
# With vault password prompt
ansible-playbook shutdown.yml --ask-vault-pass

# With vault password file
ansible-playbook shutdown.yml --vault-password-file=~/.vault_pass

# Dry-run (check mode — limited, since shell commands skip)
ansible-playbook shutdown.yml --ask-vault-pass --check

# Run only specific phases
ansible-playbook shutdown.yml --ask-vault-pass --tags backup
ansible-playbook shutdown.yml --ask-vault-pass --tags drain
ansible-playbook shutdown.yml --ask-vault-pass --tags shutdown
```

### Cluster Startup (Manual)

```bash
ansible-playbook startup.yml --ask-vault-pass

# Power on VMs only (skip health checks)
ansible-playbook startup.yml --ask-vault-pass --tags startup

# Run health checks only (VMs already running)
ansible-playbook startup.yml --ask-vault-pass --tags healthcheck
```

### Automated Shutdown via NUT

1. Copy `nut/upsmon.conf.example` into `/etc/nut/upsmon.conf` and adjust UPS name/credentials.

2. Deploy the project to `/opt/okd-shutdown/` on the management VM.

3. Store the vault password:

   ```bash
   echo 'your-vault-password' > /opt/okd-shutdown/.vault_pass
   chmod 600 /opt/okd-shutdown/.vault_pass
   ```

4. Make the trigger script executable:

   ```bash
   chmod +x /opt/okd-shutdown/scripts/trigger-shutdown.sh
   ```

5. Restart NUT:

   ```bash
   systemctl restart nut-monitor
   ```

When the UPS reaches critical battery, NUT calls `SHUTDOWNCMD` which triggers `scripts/trigger-shutdown.sh`.

### Running via AWX / Ansible Tower

AWX provides a web UI, RBAC, audit logging, and scheduling on top of Ansible. This project works with AWX without modification — you only need to configure projects, credentials, inventories, and job templates.

#### 1. Project

Create an AWX **Project** pointing to this Git repository (or a local checkout):

| Field | Value |
|---|---|
| SCM Type | Git |
| SCM URL | `https://github.com/<org>/okd-clean-cluster-shutdown.git` |
| SCM Branch | `main` (or your release branch) |
| Update on Launch | Enabled |

#### 2. Credentials

Create the following credential types in AWX:

- **Vault Credential** (type: *Vault*) — the Ansible Vault password used to decrypt `vault.yml` files.
- **vCenter Credential** (optional) — if you prefer AWX to inject `vcenter_username` / `vcenter_password` as extra variables rather than reading them from the vault file, create a *Machine* or *Custom* credential and map the fields to extra variables.

#### 3. Inventories

Create one **AWX Inventory** per cluster, each sourced from the corresponding inventory file:

| AWX Inventory Name | Inventory Source |
|---|---|
| okd-prod | `inventories/okd-prod/hosts.yml` |
| okd-staging | `inventories/okd-staging/hosts.yml` |

Since the playbooks run on `localhost`, the inventory source is straightforward — AWX just needs the `group_vars/` from each cluster directory.

Alternatively, use a single AWX inventory and pass the inventory path as an extra variable via `-i`.

#### 4. Job Templates

Create one job template per operation per cluster, or use **Survey** fields to make them generic:

**Dedicated templates (recommended for clarity):**

| Template Name | Playbook | Inventory | Credentials |
|---|---|---|---|
| OKD Prod — Shutdown | `shutdown.yml` | okd-prod | Vault |
| OKD Prod — Startup | `startup.yml` | okd-prod | Vault |
| OKD Staging — Shutdown | `shutdown.yml` | okd-staging | Vault |
| OKD Staging — Startup | `startup.yml` | okd-staging | Vault |

**Generic template with survey:**

Create a single "OKD Shutdown" template with a survey variable `cluster_env` (choices: `okd-prod`, `okd-staging`, etc.) and set the inventory source dynamically, or override with extra variables.

Optional job template settings:
- **Job Tags**: Set to `backup`, `drain`, or `shutdown` to run individual phases.
- **Extra Variables**: Override any `group_vars` value (e.g., `drain_timeout_seconds: 600`).
- **Verbosity**: Set to 1 (`-v`) or higher for debugging.

#### 5. Workflow Templates (Multi-Cluster)

To shut down multiple clusters in a controlled order, create an AWX **Workflow Template**:

```
┌─────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Shutdown        │────▶│  Shutdown         │────▶│  Shutdown mgmt   │
│  okd-staging     │     │  okd-prod         │     │  VM (optional)   │
└─────────────────┘     └──────────────────┘     └──────────────────┘
```

- Staging shuts down first (less critical).
- Production shuts down after staging succeeds.
- Each node in the workflow is a job template from step 4.
- Add failure handlers or notification templates as needed.

For startup, reverse the order:

```
┌─────────────────┐     ┌──────────────────┐
│  Startup         │────▶│  Startup          │
│  okd-prod        │     │  okd-staging      │
└─────────────────┘     └──────────────────┘
```

#### 6. Scheduling

AWX schedules can trigger job or workflow templates on a cron schedule. Use cases:
- **Nightly shutdown** of non-production clusters to save resources.
- **Morning startup** before business hours.
- **Maintenance windows** — shutdown before, startup after.

---

## Shutdown Sequence (Detailed)

| Step | Role | Action |
|------|------|--------|
| 1 | `backup` | Verify cluster API is reachable |
| 2 | `backup` | Run `oc adm cluster-backup` with timestamped output dir |
| 3 | `backup` | Verify backup artifacts exist |
| 4 | `backup` | Prune old backups beyond retention count |
| 5 | `drain` | Discover worker nodes via label selector |
| 6 | `drain` | Cordon all workers (mark unschedulable) |
| 7 | `drain` | Drain all workers (evict pods, respecting PDBs) |
| 8 | `vm_shutdown` | Query vSphere for worker VM power state |
| 9 | `vm_shutdown` | Guest-shutdown all powered-on worker VMs |
| 10 | `vm_shutdown` | Wait for workers to reach `poweredOff` |
| 11 | `vm_shutdown` | Configurable delay before control-plane shutdown |
| 12 | `vm_shutdown` | Shut down control-plane VMs **one-by-one** |
| 13 | `vm_shutdown` | Each CP: shutdown, verify poweredOff, delay |
| 14 | — | Log completion |

### Quorum Awareness

For a 3-node etcd cluster, majority quorum = 2 nodes. The control-plane shutdown sequence:

1. **Shut down CP-0** → 2 remain → **quorum intact**
2. **Shut down CP-1** → 1 remains → quorum lost (intentional, full shutdown)
3. **Shut down CP-2** → 0 remain → cluster fully off

Each step waits for the VM to reach `poweredOff` and pauses `delay_between_control_plane_shutdown` seconds before the next, giving etcd time to transfer leadership.

---

## Startup Sequence (Detailed)

| Step | Role | Action |
|------|------|--------|
| 1 | `vm_startup` | Power on all control-plane VMs |
| 2 | `vm_startup` | Wait for `poweredOn` state |
| 3 | `vm_startup` | Pause for API/etcd stabilization |
| 4 | `vm_startup` | Power on all worker VMs |
| 5 | `vm_startup` | Wait for `poweredOn` state |
| 6 | `healthcheck` | Wait for cluster API reachability |
| 7 | `healthcheck` | Wait for all nodes to be Ready |
| 8 | `healthcheck` | Uncordon worker nodes |
| 9 | `healthcheck` | Verify all ClusterOperators are Available and not Degraded |
| 10 | `healthcheck` | Verify etcd cluster health |

---

## Configurable Variables

All variables are in `inventory/group_vars/all.yml` (single cluster) or `inventories/<cluster>/group_vars/all.yml` (multi-cluster):

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | `okd-prod` | Used in backup directory naming |
| `kubeconfig_path` | `/home/ansible/.kube/config` | Path to cluster-admin kubeconfig |
| `oc_binary` | `/usr/local/bin/oc` | Path to `oc` CLI |
| `backup_dir` | `/var/lib/etcd-backups` | etcd backup destination |
| `backup_retention_count` | `5` | Number of backups to keep |
| `drain_timeout_seconds` | `300` | Max time to wait for pod eviction |
| `drain_grace_period_seconds` | `30` | Pod termination grace period |
| `drain_skip_daemonsets` | `true` | Skip DaemonSet pods during drain |
| `drain_delete_emptydir_data` | `true` | Delete emptyDir volumes |
| `drain_force` | `true` | Force drain unmanaged pods |
| `vcenter_hostname` | — | vCenter/ESXi hostname |
| `vcenter_datacenter` | `DC1` | vSphere datacenter name |
| `worker_vms` | `[]` | List of worker VM names in vSphere |
| `control_plane_vms` | `[]` | List of control-plane VM names in vSphere |
| `delay_after_workers_shutdown` | `30` | Seconds to wait after workers are off |
| `delay_between_control_plane_shutdown` | `15` | Seconds between each CP shutdown |
| `delay_after_control_plane_power_on` | `60` | Seconds to wait after CP VMs start |
| `delay_after_workers_power_on` | `30` | Seconds to wait after worker VMs start |
| `api_health_retries` | `30` | Retry count for API health check |
| `api_health_delay` | `20` | Seconds between API health retries |
| `node_ready_retries` | `40` | Retry count for node readiness |
| `node_ready_delay` | `15` | Seconds between node readiness retries |
| `cluster_operator_retries` | `60` | Retry count for ClusterOperator checks |
| `cluster_operator_delay` | `20` | Seconds between CO check retries |

---

## Error Handling and Recovery

### Idempotency

Every role is safe to re-run:
- **backup**: Creates a new timestamped backup; prunes old ones.
- **drain**: Cordoning an already-cordoned node is a no-op. Draining an empty node succeeds immediately.
- **vm_shutdown**: Checks `hw_power_status` before sending shutdown. Already-off VMs are skipped.
- **vm_startup**: Checks `hw_power_status` before powering on. Already-on VMs are skipped.
- **healthcheck**: Pure read operations with retries.

### Partial Failure Recovery

If the playbook fails mid-run:

```bash
# Resume from a specific task
ansible-playbook shutdown.yml --ask-vault-pass --start-at-task="workers | Graceful guest shutdown"

# Skip backup and drain if already done, jump to VM shutdown
ansible-playbook shutdown.yml --ask-vault-pass --tags shutdown
```

### Retry Files

Failed playbooks produce `.retry` files in `./logs/`. Re-run with `--limit` to target only failed hosts (though this project runs only on localhost).

---

## Security Notes

- **Never commit `vault.yml` unencrypted.** Always encrypt with `ansible-vault encrypt`.
- **Never commit `.vault_pass`.** Add it to `.gitignore`.
- The project does not SSH into RHCOS nodes. All operations use the `oc` CLI and VMware API.
- vCenter credentials are stored exclusively in the vault-encrypted file.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `oc cluster-info` fails | Expired/wrong kubeconfig | Re-export or regenerate kubeconfig |
| `vmware_guest_powerstate` timeout | VMware Tools not installed/running | Ensure RHCOS VMs have open-vm-tools |
| Drain stuck on PDB | PodDisruptionBudget blocks eviction | Increase `drain_timeout_seconds` or check PDB |
| ClusterOperator degraded after startup | Operators still reconciling | Increase `cluster_operator_retries` / `cluster_operator_delay` |
| NUT doesn't trigger | `SHUTDOWNCMD` path wrong | Verify path in `upsmon.conf`, check NUT logs |

---

## Testing Without a Cluster or vSphere

The project includes an offline testing framework under `tests/` that lets you validate playbook syntax, role logic, and task flow without access to a real OKD cluster or VMware vSphere environment.

### How It Works

The test setup has two parts:

1. **Mock `oc` binary** (`tests/mock-bin/oc`) — a shell script that returns canned JSON/text for every `oc` subcommand the playbooks call (`cluster-info`, `get nodes`, `adm drain`, `get clusteroperators`, etc.).
2. **Test inventory** (`tests/test-inventory/`) — variables that point `oc_binary` at the mock, set minimal timeouts/delays, and write artifacts to `/tmp`.

This exercises the **backup**, **drain**, and **healthcheck** roles end-to-end using the mock. The **vm_shutdown** and **vm_startup** roles use `community.vmware` modules that require a real vSphere connection, so those are tested with `--check` mode only (Ansible evaluates the task structure but skips API calls).

### Running the Test Suite

```bash
# Make the test runner and mock executable
chmod +x tests/run-tests.sh tests/mock-bin/oc

# Run all tests
./tests/run-tests.sh
```

The test runner performs:

| Test | What It Validates |
|---|---|
| Syntax check (`shutdown.yml`, `startup.yml`) | YAML parsing, role resolution, variable references |
| Mock `oc` smoke tests | Mock returns valid JSON, correct number of nodes/operators |
| Backup role (mock oc) | Directory creation, backup command, artifact verification, pruning |
| Drain role (mock oc) | Worker discovery, cordon, drain command construction |
| Healthcheck role (mock oc) | API check, node readiness, uncordon, ClusterOperator parsing, etcd status |
| VMware roles (`--check` mode) | Task structure validation without vSphere connection |

### Running Individual Tests Manually

```bash
# Syntax check only
ansible-playbook shutdown.yml -i tests/test-inventory/ --syntax-check
ansible-playbook startup.yml  -i tests/test-inventory/ --syntax-check

# Run backup role with mock oc
ansible-playbook shutdown.yml -i tests/test-inventory/ --tags backup

# Run drain role with mock oc
ansible-playbook shutdown.yml -i tests/test-inventory/ --tags drain

# Run healthcheck role with mock oc
ansible-playbook startup.yml -i tests/test-inventory/ --tags healthcheck

# Dry-run VMware roles (check mode)
ansible-playbook shutdown.yml -i tests/test-inventory/ --tags shutdown --check
ansible-playbook startup.yml  -i tests/test-inventory/ --tags startup --check

# Full shutdown playbook (backup + drain only, skip VMware)
ansible-playbook shutdown.yml -i tests/test-inventory/ --tags backup,drain

# Verbose output for debugging
ansible-playbook shutdown.yml -i tests/test-inventory/ --tags backup -vvv
```

### Extending the Mock

To test error scenarios, modify `tests/mock-bin/oc` to return non-zero exit codes or altered JSON for specific subcommands. For example, to simulate a degraded ClusterOperator, edit the `get clusteroperators` response to include `"status": "True"` for the `Degraded` condition.

---

## License

MIT
