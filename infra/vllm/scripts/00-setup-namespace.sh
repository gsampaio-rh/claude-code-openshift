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
else
  echo "  WARNING: No GPU nodes detected."
  echo "  Ensure the NVIDIA GPU Operator is installed."
fi
echo ""

echo "Checking KServe CRDs..."
if oc get crd inferenceservices.serving.kserve.io &>/dev/null; then
  echo "  InferenceService CRD found."
else
  echo "  ERROR: InferenceService CRD not found."
  echo "  Ensure OpenShift AI is installed with KServe enabled."
  exit 1
fi
echo ""

echo "Namespace setup complete."
echo ""
echo "Next: deploy the model:"
echo "  ./01-deploy-model.sh"
