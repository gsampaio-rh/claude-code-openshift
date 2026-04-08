#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " AgentOps | Step 0: Cluster Validation & Namespace Setup"
echo "============================================================"
echo ""

# ── Cluster login ────────────────────────────────────────────────────────────
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi
echo "Logged in as: $(oc whoami)"
echo "Server:       $(oc whoami --show-server)"
echo ""

# ── OpenShift version ────────────────────────────────────────────────────────
echo "Checking OpenShift version..."
OCP_VERSION=$(oc version -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion','unknown'))" 2>/dev/null || echo "unknown")
echo "  Version: $OCP_VERSION"
echo ""

# ── GPU availability ─────────────────────────────────────────────────────────
echo "Checking GPU availability..."
GPU_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '$2 > 0' | wc -l | tr -d ' ')

if [[ "$GPU_NODES" -ge 1 ]]; then
  echo "  Found $GPU_NODES node(s) with NVIDIA GPUs."
else
  echo "  WARNING: No GPU nodes detected."
  echo "  Model serving requires at least one NVIDIA GPU."
  echo "  Ensure the NVIDIA GPU Operator is installed."
fi
echo ""

# ── Namespaces ───────────────────────────────────────────────────────────────
echo "Creating namespaces..."
oc apply -f "$MANIFESTS_DIR/namespaces.yaml"
echo ""

# ── NetworkPolicies ──────────────────────────────────────────────────────────
echo "Applying NetworkPolicies..."
oc apply -f "$MANIFESTS_DIR/network-policies.yaml"
echo ""

# ── ResourceQuotas ───────────────────────────────────────────────────────────
echo "Applying ResourceQuotas..."
oc apply -f "$MANIFESTS_DIR/resource-quotas.yaml"
echo ""

# ── RBAC ─────────────────────────────────────────────────────────────────────
echo "Applying RBAC..."
oc apply -f "$MANIFESTS_DIR/rbac.yaml"
echo ""

echo "Cluster setup complete."
echo ""
echo "Next: install operators:"
echo "  ./02-install-operators.sh"
