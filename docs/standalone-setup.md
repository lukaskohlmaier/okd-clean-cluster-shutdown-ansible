# Standalone Setup — Fresh Ubuntu VM (No AWX)

End-to-end instructions for a plain Ubuntu management VM running Ansible directly,
triggered either manually or automatically via NUT/upsmon on a UPS power event.

---

## Assumptions

- Fresh Ubuntu 22.04 or 24.04 VM (on VMware or bare metal)
- The VM has network access to your OKD cluster API and vCenter
- You have a cluster-admin kubeconfig for each OKD cluster
- You have a UPS connected via USB passthrough or SNMP (for automatic triggering)

---

## Part 1 — System Packages

```bash
sudo apt update
sudo apt install -y \
    ansible \
    python3-pip \
    python3-venv \
    git \
    curl \
    nut \
    jq
```

Verify Ansible:

```bash
ansible --version
# Should report ansible [core 2.15+]
```

---

## Part 2 — Install the `oc` CLI

```bash
# Download the latest oc binary — adjust the version as needed
OC_VERSION=4.16
curl -L "https://mirror.openshift.com/pub/openshift-v4/clients/oc/${OC_VERSION}/linux/oc.tar.gz" | tar xz
sudo mv oc /usr/local/bin/oc
oc version --client
```

---

## Part 3 — Install Ansible Collections and Python Dependencies

```bash
# Install required collections (defined in requirements.yml)
ansible-galaxy collection install -r /opt/okd-shutdown/requirements.yml

# Install Python libraries used by the VMware collection
pip3 install pyvmomi jmespath
```

---

## Part 4 — Deploy this Project

Clone the repository to a permanent location on the management VM:

```bash
sudo mkdir -p /opt/okd-shutdown
sudo git clone https://github.com/<youruser>/okd-clean-cluster-shutdown.git /opt/okd-shutdown
sudo chown -R $USER:$USER /opt/okd-shutdown
chmod +x /opt/okd-shutdown/scripts/trigger-shutdown.sh
mkdir -p /opt/okd-shutdown/logs
```

Install collections into the project:

```bash
cd /opt/okd-shutdown
ansible-galaxy collection install -r requirements.yml
pip3 install pyvmomi jmespath
```

---

## Part 5 — Place the Kubeconfig

Copy the cluster-admin kubeconfig from your OKD cluster to the management VM.
Repeat for each cluster if you have more than one.

```bash
mkdir -p ~/.kube

# Option A — scp from bastion/bootstrap node
scp core@<bastion-host>:/etc/kubernetes/admin.kubeconfig ~/.kube/config

# Option B — paste the content directly
nano ~/.kube/config   # paste, save

chmod 600 ~/.kube/config
```

Verify access:

```bash
export KUBECONFIG=~/.kube/config
oc cluster-info
oc get nodes
```

---

## Part 6 — Configure the Inventory

### Single cluster

Edit `inventory/group_vars/all.yml`:

```yaml
cluster_name: "okd-prod"
kubeconfig_path: "/home/youruser/.kube/config"

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

### Multiple clusters

Copy an existing inventory directory for each additional cluster:

```bash
cp -r inventories/okd-prod inventories/okd-staging
```

Edit `inventories/okd-staging/group_vars/all.yml` — set at minimum:
- `cluster_name` (unique)
- `kubeconfig_path` (path to this cluster's kubeconfig)
- `backup_dir` (unique path to avoid collisions)
- `vcenter_hostname` / `vcenter_datacenter`
- `worker_vms` / `control_plane_vms`

---

## Part 7 — Set up Vault Credentials

The `vault.yml` file holds your vCenter username and password. It must be encrypted
before committing to Git.

### Create / edit the vault file

```bash
# Single cluster
ansible-vault edit inventory/group_vars/vault.yml

# Per-cluster
ansible-vault edit inventories/okd-prod/group_vars/vault.yml
ansible-vault edit inventories/okd-staging/group_vars/vault.yml
```

Content of each `vault.yml`:

```yaml
vault_vcenter_username: "administrator@vsphere.local"
vault_vcenter_password: "your-vcenter-password"
```

### Encrypt vault files

```bash
ansible-vault encrypt inventory/group_vars/vault.yml
ansible-vault encrypt inventories/okd-prod/group_vars/vault.yml
ansible-vault encrypt inventories/okd-staging/group_vars/vault.yml
```

You will be prompted to set a vault password. **Choose one strong password and use
the same one for all files** — it makes automation simpler.

### Store the vault password on disk

So that automated triggers (NUT/cron) can run without prompting:

```bash
echo 'your-vault-password' > /opt/okd-shutdown/.vault_pass
chmod 600 /opt/okd-shutdown/.vault_pass
```

Never commit `.vault_pass` to Git. Add it to `.gitignore`:

```bash
echo '.vault_pass' >> /opt/okd-shutdown/.gitignore
```

---

## Part 8 — Run the Playbooks Manually

### Shutdown

```bash
cd /opt/okd-shutdown

# Single cluster — prompt for vault password
ansible-playbook shutdown.yml --ask-vault-pass

# Single cluster — vault password from file (no prompt)
ansible-playbook shutdown.yml --vault-password-file=.vault_pass

# Specific cluster inventory
ansible-playbook shutdown.yml \
    -i inventories/okd-prod/hosts.yml \
    --vault-password-file=.vault_pass

# Run only specific phases
ansible-playbook shutdown.yml --vault-password-file=.vault_pass --tags backup
ansible-playbook shutdown.yml --vault-password-file=.vault_pass --tags drain
ansible-playbook shutdown.yml --vault-password-file=.vault_pass --tags shutdown

# Dry run (check mode)
ansible-playbook shutdown.yml --vault-password-file=.vault_pass --check
```

### Startup

```bash
ansible-playbook startup.yml --vault-password-file=.vault_pass

# Specific cluster
ansible-playbook startup.yml \
    -i inventories/okd-prod/hosts.yml \
    --vault-password-file=.vault_pass

# Power on VMs only, skip health checks
ansible-playbook startup.yml --vault-password-file=.vault_pass --tags startup

# Health checks only (VMs already on)
ansible-playbook startup.yml --vault-password-file=.vault_pass --tags healthcheck
```

### Shut down all clusters sequentially

```bash
for cluster in /opt/okd-shutdown/inventories/*/; do
    echo "==> Shutting down ${cluster}"
    ansible-playbook /opt/okd-shutdown/shutdown.yml \
        -i "${cluster}hosts.yml" \
        --vault-password-file=/opt/okd-shutdown/.vault_pass
done
```

---

## Part 9 — NUT / upsmon Setup (Automatic UPS Trigger)

NUT monitors the UPS and executes `scripts/trigger-shutdown.sh` when battery
reaches a critical level. The script then runs `ansible-playbook shutdown.yml`
and optionally powers off the management VM last.

### 9.1 How it fits together

```
UPS battery critical / FSD signal
    │
    ▼ (USB or SNMP, polled every 5 s)
upsd reads UPS status via driver
    │
    ▼
upsmon detects LOWBATT / FSD state
    │ SHUTDOWNCMD
    ▼
/opt/okd-shutdown/scripts/trigger-shutdown.sh
    │
    ├── ansible-playbook shutdown.yml
    │       ├── backup   (etcd snapshot)
    │       ├── drain    (cordon + evict pods)
    │       └── vm_shutdown (workers → CPs, one by one)
    │
    └── /sbin/shutdown -h now   ← management VM last (optional)
```

### 9.2 Determine your UPS connection type

| Situation | Driver |
|---|---|
| UPS plugged into this VM via USB | `usbhid-ups` |
| UPS has a network/SNMP management card | `snmp-ups` |
| UPS is on another host and exposed over network | `upsd` on that host; `netclient` mode here |

> **VMware USB note:** ESXi does not automatically pass USB devices into guest VMs.
> You must either:
> - Enable USB passthrough for this VM in vSphere (_Edit Settings → USB Controller → Add USB device_)
> - Use a network-capable UPS with SNMP, or
> - Run `upsd` on a physical host that has USB access and point `upsmon` here at `myups@<that-host>`

### 9.3 Write the NUT config files

#### `/etc/nut/nut.conf`

```
MODE=standalone
```

> Change to `MODE=netclient` if `upsd` runs on a different machine.

#### `/etc/nut/ups.conf`

**USB:**
```
[myups]
    driver = usbhid-ups
    port   = auto
    desc   = "UPS via USB"
```

**SNMP/network:**
```
[myups]
    driver    = snmp-ups
    port      = 192.0.2.10     # UPS management card IP
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

> This password is only used for localhost communication between `upsmon` and `upsd`.
> It is **not** the Ansible Vault password.

#### `/etc/nut/upsmon.conf`

```
MONITOR myups@localhost 1 upsmon_user secret_password master

SHUTDOWNCMD "/opt/okd-shutdown/scripts/trigger-shutdown.sh"

NOTIFYFLAG ONLINE   SYSLOG+EXEC
NOTIFYFLAG ONBATT   SYSLOG+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+EXEC
NOTIFYFLAG FSD      SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC

DEADTIME      30    # ignore outages shorter than 30 seconds
POLLFREQ       5    # poll upsd every 5 seconds (normal)
POLLFREQALERT  2    # poll every 2 seconds when on battery
FINALDELAY     0    # playbook controls timing, not NUT
```

### 9.4 Enable and start NUT

```bash
sudo systemctl enable --now nut-server nut-monitor
```

### 9.5 Verify the UPS is detected

```bash
upsc myups@localhost
# Should list ups.status: OL   (on-line)
# On battery it will show: ups.status: OB
```

Check service logs if something is wrong:

```bash
sudo journalctl -u nut-server -u nut-monitor -f
```

Common issues:

| Symptom | Likely cause | Fix |
|---|---|---|
| `can't connect to upsd` | `nut-server` not running | `systemctl start nut-server` |
| `Driver failed to start` | Wrong driver or USB not passed through | Check `ups.conf` driver; verify USB passthrough in vSphere |
| `Data stale` in `ups.status` | Driver lost contact with UPS | Check cable / SNMP reachability |
| `upsmon` exits immediately | Password mismatch | Ensure `upsd.users` and `upsmon.conf` use the same password |

### 9.6 Test the trigger without cutting power

```bash
sudo /opt/okd-shutdown/scripts/trigger-shutdown.sh
```

Watch the log in real time:

```bash
tail -f /opt/okd-shutdown/logs/nut-trigger-*.log
```

---

## Part 10 — (Optional) Schedule with Cron

For planned shutdown windows (e.g. nightly non-prod shutdown) without a UPS event:

```bash
sudo crontab -e
```

Add:

```cron
# Shut down OKD staging every weekday at 22:00
0 22 * * 1-5 /opt/okd-shutdown/scripts/trigger-shutdown.sh >> /opt/okd-shutdown/logs/cron-shutdown.log 2>&1
```

Or trigger the playbook directly without going through the NUT script:

```cron
0 22 * * 1-5 ansible-playbook /opt/okd-shutdown/shutdown.yml \
    -i /opt/okd-shutdown/inventories/okd-staging/hosts.yml \
    --vault-password-file=/opt/okd-shutdown/.vault_pass \
    >> /opt/okd-shutdown/logs/cron-shutdown.log 2>&1
```

---

## Quick Reference

| Action | Command |
|---|---|
| Manual shutdown (prod) | `ansible-playbook shutdown.yml -i inventories/okd-prod/hosts.yml --vault-password-file=.vault_pass` |
| Manual startup (prod) | `ansible-playbook startup.yml -i inventories/okd-prod/hosts.yml --vault-password-file=.vault_pass` |
| Backup only | `ansible-playbook shutdown.yml --vault-password-file=.vault_pass --tags backup` |
| Drain only | `ansible-playbook shutdown.yml --vault-password-file=.vault_pass --tags drain` |
| Health check only | `ansible-playbook startup.yml --vault-password-file=.vault_pass --tags healthcheck` |
| Check UPS status | `upsc myups@localhost` |
| Watch NUT logs | `sudo journalctl -u nut-server -u nut-monitor -f` |
| Test trigger manually | `sudo /opt/okd-shutdown/scripts/trigger-shutdown.sh` |
| Edit vault secrets | `ansible-vault edit inventories/okd-prod/group_vars/vault.yml` |
| View vault secrets | `ansible-vault view inventories/okd-prod/group_vars/vault.yml` |
