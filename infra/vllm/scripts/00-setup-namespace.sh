#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " vLLM | Step 0: Setup Namespace"
echo "============================================================"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi
echo "Logged in as: $(oc whoami)"
echo ""

echo "Checking namespace '$NAMESPACE'..."
if oc get namespace "$NAMESPACE" &>/dev/null; then
  echo "  Namespace exists."
else
  echo "  Creating namespace '$NAMESPACE'..."
  oc create namespace "$NAMESPACE"
  oc label namespace "$NAMESPACE" opendatahub.io/dashboard=true --overwrite
fi
echo ""

echo "Checking GPU availability..."
GPU_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '$2 > 0' | wc -l | tr -d ' ')

if [[ "$GPU_NODES" -ge 1 ]]; then
  echo "  Found $GPU_NODES node(s) with NVIDIA GPUs."
  oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\t"}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' 2>/dev/null \
    | awk '$2 > 0 {printf "    %s — %s GPU(s) — %s\n", $1, $2, $3}'
else
  echo "  WARNING: No GPU nodes detected."
  echo "  Ensure the NVIDIA GPU Operator is installed and a GPU MachineSet exists."
fi
echo ""

echo "Checking StorageClass for PVC..."
if oc get storageclass gp3-csi &>/dev/null; then
  echo "  StorageClass gp3-csi found."
elif oc get storageclass gp2-csi &>/dev/null; then
  echo "  StorageClass gp2-csi found (update pvc.yaml if using gp2-csi)."
else
  echo "  WARNING: No gp3-csi or gp2-csi StorageClass found."
  echo "  Available StorageClasses:"
  oc get storageclass -o name 2>/dev/null | sed 's/^/    /'
fi
echo ""

echo "Namespace setup complete."
echo ""
echo "Next: deploy the model:"
echo "  ./01-deploy-model.sh"
