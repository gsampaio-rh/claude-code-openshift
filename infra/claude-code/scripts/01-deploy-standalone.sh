#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Claude Code | Step 1: Deploy Standalone Agent"
echo "============================================================"
echo ""

echo "── Applying ConfigMap ──"
oc apply -f "$MANIFESTS_DIR/configmap.yaml"
echo ""

echo "── Deploying standalone pod ──"
oc apply -f "$MANIFESTS_DIR/standalone-pod.yaml"
echo ""

echo "── Waiting for pod to be ready ──"
oc wait --for=condition=Ready \
  "pod/$POD_NAME" \
  -n "$NAMESPACE" \
  --timeout=120s
echo ""

echo "── Verifying Claude Code CLI ──"
oc exec -n "$NAMESPACE" "$POD_NAME" -- claude --version
echo ""

echo "Standalone agent is ready."
echo ""
echo "  To interact:"
echo "    oc exec -it -n $NAMESPACE $POD_NAME -- claude"
echo ""
echo "  Headless mode:"
echo "    oc exec -n $NAMESPACE $POD_NAME -- claude -p 'Write a fibonacci function in Python'"
echo ""
echo "Next: verify connectivity to vLLM:"
echo "  ./99-verify.sh"
