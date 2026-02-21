#!/usr/bin/env bash
# =============================================================================
# trigger-shutdown.sh — Called by NUT upsmon SHUTDOWNCMD
# =============================================================================
# This script is invoked when NUT detects a critical battery / FSD condition.
# It runs the Ansible shutdown playbook, logs output, and (optionally) shuts
# down the management VM itself after the cluster is off.
# =============================================================================
set -euo pipefail

# ---- Configuration ----------------------------------------------------------
PROJECT_DIR="/opt/okd-shutdown"
VAULT_PASS_FILE="${PROJECT_DIR}/.vault_pass"
LOG_FILE="${PROJECT_DIR}/logs/nut-trigger-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/tmp/okd-shutdown.lock"
SHUTDOWN_MGMT_VM=true   # Set to false to keep management VM running

# ---- Prevent concurrent runs ------------------------------------------------
if [ -f "${LOCK_FILE}" ]; then
    echo "$(date -Iseconds) Shutdown already in progress (lock: ${LOCK_FILE}). Exiting." | tee -a "${LOG_FILE}"
    exit 0
fi
trap 'rm -f "${LOCK_FILE}"' EXIT
touch "${LOCK_FILE}"

# ---- Run playbook ------------------------------------------------------------
echo "$(date -Iseconds) NUT triggered OKD cluster shutdown." | tee -a "${LOG_FILE}"

cd "${PROJECT_DIR}"

ansible-playbook shutdown.yml \
    --vault-password-file="${VAULT_PASS_FILE}" \
    2>&1 | tee -a "${LOG_FILE}"

PLAYBOOK_RC=${PIPESTATUS[0]}

if [ "${PLAYBOOK_RC}" -ne 0 ]; then
    echo "$(date -Iseconds) WARNING: Playbook exited with rc=${PLAYBOOK_RC}." | tee -a "${LOG_FILE}"
fi

echo "$(date -Iseconds) OKD shutdown playbook finished (rc=${PLAYBOOK_RC})." | tee -a "${LOG_FILE}"

# ---- Optionally shut down the management VM itself ---------------------------
if [ "${SHUTDOWN_MGMT_VM}" = true ]; then
    echo "$(date -Iseconds) Shutting down management VM in 10 seconds..." | tee -a "${LOG_FILE}"
    sleep 10
    /sbin/shutdown -h now "OKD cluster shutdown complete — powering off management VM"
fi
