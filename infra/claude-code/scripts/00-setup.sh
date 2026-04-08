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
  echo "  Run cluster setup first: cd ../../cluster/scripts && ./01-setup-cluster.sh"
  exit 1
fi
echo ""

echo "Checking vLLM availability..."
ENDPOINT="http://${MODEL_NAME}-predictor.${NAMESPACE_INFERENCE}.svc.cluster.local:8080/v1"
if oc get inferenceservice "$MODEL_NAME" -n "$NAMESPACE_INFERENCE" &>/dev/null; then
  IS_READY=$(oc get inferenceservice "$MODEL_NAME" -n "$NAMESPACE_INFERENCE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  echo "  InferenceService found. Ready: ${IS_READY:-unknown}"
  echo "  Endpoint: $ENDPOINT"
else
  echo "  WARNING: InferenceService '$MODEL_NAME' not found."
  echo "  Deploy vLLM first: cd ../../vllm && ./scripts/01-deploy-model.sh"
fi
echo ""

echo "Setup complete."
echo ""
echo "Next: deploy the standalone agent:"
echo "  ./01-deploy-standalone.sh"
