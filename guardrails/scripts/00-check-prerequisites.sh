#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Guardrails | Step 0: Verify Prerequisites"
echo "============================================================"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi
echo "Logged in as: $(oc whoami)"
echo ""

echo "Checking model '$MODEL_NAME'..."
if oc get deployment "$MODEL_NAME" -n "$NAMESPACE" &>/dev/null; then
  READY=$(oc get deployment "$MODEL_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  echo "  Deployment found. Ready replicas: ${READY:-0}"
else
  echo "  ERROR: Deployment '$MODEL_NAME' not found in '$NAMESPACE'."
  echo "  Deploy vLLM first: cd ../../inference/vllm/scripts && ./01-deploy-model.sh"
  exit 1
fi
echo ""

echo "Checking TrustyAI CRDs..."
if oc get crd guardrailsorchestrators.trustyai.opendatahub.io &>/dev/null; then
  echo "  GuardrailsOrchestrator CRD found."
else
  echo "  ERROR: GuardrailsOrchestrator CRD not found."
  echo "  Ensure TrustyAI is enabled in DataScienceCluster (managementState: Managed)."
  exit 1
fi
echo ""

echo "Prerequisites verified."
echo ""
echo "Next: deploy guardrails:"
echo "  ./01-deploy-guardrails.sh"
