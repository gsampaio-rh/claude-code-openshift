#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Guardrails | Step 1: Deploy Guardrails Orchestrator"
echo "============================================================"
echo ""

echo "Deploying orchestrator configuration..."
oc apply -n "$NAMESPACE" -f "$MANIFESTS_DIR/orchestrator-config.yaml"
echo ""

echo "Deploying gateway configuration..."
oc apply -n "$NAMESPACE" -f "$MANIFESTS_DIR/gateway-config.yaml"
echo ""

echo "Deploying GuardrailsOrchestrator..."
oc apply -n "$NAMESPACE" -f "$MANIFESTS_DIR/guardrails-orchestrator.yaml"
echo ""

echo "Waiting for orchestrator pod (timeout: $ORCHESTRATOR_READY_TIMEOUT)..."
oc wait --for=condition=Available \
  "deployment/${ORCHESTRATOR_NAME}" \
  -n "$NAMESPACE" \
  --timeout="$ORCHESTRATOR_READY_TIMEOUT" 2>/dev/null || {
    echo "Waiting for pod directly..."
    oc wait --for=condition=Ready pod \
      -l "app=${ORCHESTRATOR_NAME}" \
      -n "$NAMESPACE" \
      --timeout="$ORCHESTRATOR_READY_TIMEOUT"
  }

echo ""
echo "Guardrails Orchestrator deployed."
echo ""
echo "Available gateway routes:"
echo "  /pii/v1/chat/completions         — PII detection"
echo "  /safety/v1/chat/completions      — full safety pipeline"
echo "  /injection/v1/chat/completions   — prompt injection detection"
echo "  /passthrough/v1/chat/completions — no detectors (baseline)"
echo ""
echo "Next: verify:"
echo "  ./99-verify.sh"
