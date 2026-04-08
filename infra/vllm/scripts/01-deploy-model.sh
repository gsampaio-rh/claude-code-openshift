#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " vLLM | Step 1: Deploy $MODEL_NAME"
echo "============================================================"
echo ""
echo "  Model:     $MODEL_HF_URI"
echo "  Namespace: $NAMESPACE"
echo "  Context:   $MAX_MODEL_LEN tokens"
echo "  GPU:       ${GPU_COUNT}x"
echo ""

echo "── Applying manifests ──"
oc apply -k "$MANIFESTS_DIR"
echo ""

echo "── Waiting for InferenceService to be ready (timeout: $MODEL_READY_TIMEOUT) ──"
echo "  First boot downloads the model from HuggingFace (~3-5 min)."
echo ""

oc wait --for=condition=Ready \
  "inferenceservice/$MODEL_NAME" \
  -n "$NAMESPACE" \
  --timeout="$MODEL_READY_TIMEOUT"

echo ""
echo "Model serving is ready."
echo ""

ENDPOINT="http://${MODEL_NAME}-predictor.${NAMESPACE}.svc.cluster.local:8080/v1"
echo "  Internal endpoint: $ENDPOINT"
echo ""
echo "Next: verify the deployment:"
echo "  ./99-verify.sh"
