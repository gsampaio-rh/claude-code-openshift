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
if oc get inferenceservice "$MODEL_NAME" -n "$NAMESPACE" &>/dev/null; then
  IS_READY=$(oc get inferenceservice "$MODEL_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  echo "  InferenceService found. Ready: ${IS_READY:-unknown}"
else
  echo "  ERROR: InferenceService '$MODEL_NAME' not found in '$NAMESPACE'."
  echo "  Deploy vLLM first: cd ../vllm && ./scripts/01-deploy-model.sh"
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
