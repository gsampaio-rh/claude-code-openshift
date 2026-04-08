#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0; WARN=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
check() { local desc="$1"; shift; if "$@" &>/dev/null; then pass "$desc"; else fail "$desc"; fi; }

echo "============================================================"
echo " Guardrails | Verification"
echo "============================================================"
echo ""

echo "Orchestrator"
check "ConfigMap '$ORCHESTRATOR_CONFIG_NAME' exists" \
  oc get configmap "$ORCHESTRATOR_CONFIG_NAME" -n "$NAMESPACE"
check "ConfigMap '$GATEWAY_CONFIG_NAME' exists" \
  oc get configmap "$GATEWAY_CONFIG_NAME" -n "$NAMESPACE"
check "GuardrailsOrchestrator CR exists" \
  oc get guardrailsorchestrator "$ORCHESTRATOR_NAME" -n "$NAMESPACE"

RUNNING_PODS=$(oc get pods -n "$NAMESPACE" \
  -l "app=${ORCHESTRATOR_NAME}" \
  --field-selector=status.phase=Running \
  -o name 2>/dev/null | wc -l | tr -d ' ')
if [[ "$RUNNING_PODS" -ge 1 ]]; then
  pass "Orchestrator pod running ($RUNNING_PODS replica(s))"
else
  fail "No running orchestrator pods found"
fi
echo ""

echo "Functional Test — PII detection"
GW_HOST=$(oc get route guardrails-orchestrator-gateway -n "$NAMESPACE" \
  -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

if [[ -n "$GW_HOST" ]]; then
  RESULT=$(curl -sk -X POST "https://$GW_HOST/pii/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"my cpf is 123.456.789-00\"}],\"max_tokens\":10}" 2>/dev/null || echo "")
  if echo "$RESULT" | grep -q "UNSUITABLE_INPUT"; then
    pass "PII detection blocked CPF"
  else
    fail "PII detection did not block CPF (response: ${RESULT:0:100})"
  fi

  RESULT=$(curl -sk -X POST "https://$GW_HOST/passthrough/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a hello world in Python\"}],\"max_tokens\":50}" 2>/dev/null || echo "")
  if echo "$RESULT" | grep -q '"choices"'; then
    pass "Passthrough route returns model response"
  else
    fail "Passthrough route failed (response: ${RESULT:0:100})"
  fi
else
  warn "No gateway route found — skipping functional tests"
fi
echo ""

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1
echo ""
echo "Guardrails stack is operational."
