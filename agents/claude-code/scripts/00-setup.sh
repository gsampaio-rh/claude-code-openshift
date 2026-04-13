#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Claude Code | Step 0: Setup"
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
  echo "  ERROR: Namespace '$NAMESPACE' not found."
  echo "  Run cluster setup first: cd ../../../infra/cluster/scripts && ./01-setup-cluster.sh"
  exit 1
fi
echo ""

NAMESPACE_INFERENCE="${NAMESPACE_INFERENCE:-inference}"
echo "Checking vLLM availability..."
if oc get deployment "$MODEL_NAME" -n "$NAMESPACE_INFERENCE" &>/dev/null; then
  READY=$(oc get deployment "$MODEL_NAME" -n "$NAMESPACE_INFERENCE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  echo "  Deployment '$MODEL_NAME' found. Ready replicas: ${READY:-0}"
  echo "  Endpoint: $VLLM_ENDPOINT"

  if [[ "${READY:-0}" -ge 1 ]]; then
    echo "  Status: READY"
  else
    echo "  WARNING: Deployment exists but no ready replicas."
    echo "  Check: oc rollout status deployment/$MODEL_NAME -n $NAMESPACE_INFERENCE"
  fi
else
  echo "  WARNING: Deployment '$MODEL_NAME' not found in '$NAMESPACE_INFERENCE'."
  echo "  Deploy vLLM first: cd ../../../inference/vllm/scripts && ./01-deploy-model.sh"
fi
echo ""

echo "Setup complete."
echo ""
echo "Next: build the agent image:"
echo "  ./build-image.sh"
echo "Then deploy:"
echo "  ./01-deploy-standalone.sh"
