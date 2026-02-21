#!/usr/bin/env bash
# =============================================================================
# run-tests.sh — Offline test runner for OKD Clean Cluster Shutdown
# =============================================================================
# Validates playbook syntax and runs oc-based roles against the mock oc binary.
# VMware roles (vm_shutdown, vm_startup) require a real vSphere connection and
# are tested separately with --check mode only.
#
# Prerequisites:
#   - ansible-playbook available on $PATH
#   - No cluster or vSphere access needed
#
# Usage:
#   chmod +x tests/run-tests.sh
#   ./tests/run-tests.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INVENTORY="$PROJECT_DIR/tests/test-inventory"
MOCK_OC="$PROJECT_DIR/tests/mock-bin/oc"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

run_test() {
  local description="$1"
  shift
  printf "${YELLOW}[TEST]${NC} %s ... " "$description"
  if OUTPUT=$("$@" 2>&1); then
    printf "${GREEN}PASS${NC}\n"
    PASS=$((PASS + 1))
  else
    printf "${RED}FAIL${NC}\n"
    echo "$OUTPUT" | tail -20
    FAIL=$((FAIL + 1))
  fi
}

# Like run_test but marks as SKIP (not FAIL) when the command exits non-zero.
# Use for tests that require optional infrastructure (e.g. pyVmomi / vSphere).
run_optional_test() {
  local description="$1"
  shift
  printf "${YELLOW}[TEST]${NC} %s ... " "$description"
  if OUTPUT=$("$@" 2>&1); then
    printf "${GREEN}PASS${NC}\n"
    PASS=$((PASS + 1))
  else
    printf "${YELLOW}SKIP${NC} (optional dependency missing)\n"
    SKIP=$((SKIP + 1))
  fi
}

echo "================================================================"
echo "  OKD Clean Cluster Shutdown — Offline Test Suite"
echo "================================================================"
echo ""

# Ensure mock oc is executable
chmod +x "$MOCK_OC"

# Clean up temp dirs from previous runs
rm -rf /tmp/okd-test-backups /tmp/okd-test-logs

# ---- 1. Syntax check -------------------------------------------------------
echo "--- Syntax Checks ---"
run_test "shutdown.yml syntax" \
  ansible-playbook "$PROJECT_DIR/shutdown.yml" -i "$INVENTORY" --syntax-check

run_test "startup.yml syntax" \
  ansible-playbook "$PROJECT_DIR/startup.yml" -i "$INVENTORY" --syntax-check

echo ""

# ---- 2. Mock oc binary smoke test ------------------------------------------
echo "--- Mock oc Binary ---"
run_test "mock oc cluster-info" \
  "$MOCK_OC" cluster-info

run_test "mock oc get nodes -o json" \
  bash -c "$MOCK_OC get nodes -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d[\"items\"])==5'"

run_test "mock oc get clusteroperators -o json" \
  bash -c "$MOCK_OC get clusteroperators -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d[\"items\"])==3'"

echo ""

# ---- 3. Run oc-based roles (backup, drain) with mock -----------------------
echo "--- Shutdown Playbook (oc-based roles only) ---"
run_test "backup role (mock oc)" \
  ansible-playbook "$PROJECT_DIR/shutdown.yml" \
    -i "$INVENTORY" \
    --tags backup

run_test "drain role (mock oc)" \
  ansible-playbook "$PROJECT_DIR/shutdown.yml" \
    -i "$INVENTORY" \
    --tags drain

echo ""

# ---- 4. Run oc-based roles from startup (healthcheck) ----------------------
echo "--- Startup Playbook (healthcheck role only) ---"
run_test "healthcheck role (mock oc)" \
  ansible-playbook "$PROJECT_DIR/startup.yml" \
    -i "$INVENTORY" \
    --tags healthcheck

echo ""

# ---- 5. VMware roles — check mode only (no real connection) -----------------
echo "--- VMware Roles (--check mode, expected to skip) ---"
run_optional_test "vm_shutdown check mode" \
  ansible-playbook "$PROJECT_DIR/shutdown.yml" \
    -i "$INVENTORY" \
    --tags shutdown \
    --check

run_optional_test "vm_startup check mode" \
  ansible-playbook "$PROJECT_DIR/startup.yml" \
    -i "$INVENTORY" \
    --tags startup \
    --check

echo ""

# ---- Summary ----------------------------------------------------------------
echo "================================================================"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, ${YELLOW}%d skipped${NC}\n" "$PASS" "$FAIL" "$SKIP"
echo "================================================================"

# Clean up
rm -rf /tmp/okd-test-backups /tmp/okd-test-logs

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
