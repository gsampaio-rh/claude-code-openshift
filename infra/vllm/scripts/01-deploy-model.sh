#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " vLLM | Step 1: Deploy $MODEL_NAME"
echo "============================================================"
echo ""
echo "  Model:     $MODEL_HF_URI"
echo "  Image:     $VLLM_IMAGE"
echo "  Namespace: $NAMESPACE"
echo "  Context:   $MAX_MODEL_LEN tokens"
echo "  GPU:       ${GPU_COUNT}x"
echo ""

echo "── Applying manifests ──"
oc apply -k "$MANIFESTS_DIR"
echo ""

echo "── Waiting for Deployment rollout (timeout: $MODEL_READY_TIMEOUT) ──"
echo "  First boot pulls the image + downloads the model from HuggingFace (~5-10 min)."
echo ""

oc rollout status "deployment/$MODEL_NAME" \
  -n "$NAMESPACE" \
  --timeout="$MODEL_READY_TIMEOUT"

echo ""
echo "── Waiting for pod readiness ──"
oc wait --for=condition=Ready \
  "pod" -l "app.kubernetes.io/name=$MODEL_NAME" \
  -n "$NAMESPACE" \
  --timeout="$MODEL_READY_TIMEOUT"

echo ""
echo "Model serving is ready."
echo ""
echo "  Internal endpoint: $VLLM_ENDPOINT"
echo ""
echo "Next: validate the deployment:"
echo "  ./02-validate-model.sh"
