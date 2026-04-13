#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " AgentOps | Step 1: Install Operators"
echo "============================================================"
echo ""

# ── NFD ──────────────────────────────────────────────────────────────────────
echo "── Installing Node Feature Discovery Operator ──"
oc apply -f "$OPERATORS_DIR/nfd-operator.yaml" 2>/dev/null || \
  echo "  NFD namespace may need to be created first. Skipping NFD instance."
echo ""

# ── GPU Operator ─────────────────────────────────────────────────────────────
echo "── Installing NVIDIA GPU Operator ──"
oc apply -f "$OPERATORS_DIR/gpu-operator.yaml"
echo ""

# ── cert-manager ─────────────────────────────────────────────────────────────
echo "── Installing cert-manager Operator ──"
oc apply -f "$OPERATORS_DIR/cert-manager.yaml" 2>/dev/null || \
  echo "  cert-manager namespace may need to exist. Check OperatorHub."
echo ""

# ── Sandboxed Containers (Kata) ──────────────────────────────────────────────
echo "── Installing OpenShift Sandboxed Containers Operator ──"
echo "  NOTE: KataConfig should be applied AFTER the operator CSV is ready."
echo "  Run: oc wait --for=condition=Succeeded csv -l operators.coreos.com/sandboxed-containers-operator -n openshift-sandboxed-containers-operator --timeout=300s"
echo "  Then: oc apply -f $OPERATORS_DIR/sandboxed-containers.yaml"
echo ""

echo "Operator installation initiated."
echo "Wait for CSVs to reach 'Succeeded' status:"
echo "  oc get csv -A | grep -E 'gpu|nfd|cert-manager|sandboxed'"
echo ""
echo "Next: deploy the model:"
echo "  cd ../../../inference/vllm/scripts && ./01-deploy-model.sh"
