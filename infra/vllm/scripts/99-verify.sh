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
echo " vLLM | Verification"
echo "============================================================"
echo ""

echo "Cluster"
check "oc CLI is logged in" oc whoami
echo ""

echo "Namespace"
check "Namespace '$NAMESPACE' exists" oc get namespace "$NAMESPACE"
echo ""

echo "ServingRuntime"
check "ServingRuntime '$MODEL_NAME' exists" oc get servingruntime "$MODEL_NAME" -n "$NAMESPACE"
echo ""

echo "InferenceService"
check "InferenceService '$MODEL_NAME' exists" oc get inferenceservice "$MODEL_NAME" -n "$NAMESPACE"

IS_READY=$(oc get inferenceservice "$MODEL_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [[ "$IS_READY" == "True" ]]; then
  pass "InferenceService '$MODEL_NAME' is Ready"
else
  fail "InferenceService '$MODEL_NAME' is NOT Ready (status: ${IS_READY:-unknown})"
fi
echo ""

echo "Functional test"
ENDPOINT="http://${MODEL_NAME}-predictor.${NAMESPACE}.svc.cluster.local:8080/v1"
TEST_POD=$(oc get pods -n "$NAMESPACE" -o name 2>/dev/null | head -1 || echo "")

if [[ -n "$TEST_POD" ]]; then
  RESULT=$(oc exec -n "$NAMESPACE" "${TEST_POD}" -- \
    curl -s "${ENDPOINT}/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a Python function that returns the fibonacci sequence up to n. Only return code.\"}],\"max_tokens\":200}" \
    2>/dev/null || echo "")

  if echo "$RESULT" | grep -q '"choices"'; then
    pass "Chat completion API returned valid response"
  else
    fail "Chat completion API failed (response: ${RESULT:0:120})"
  fi
else
  warn "No pods available for functional test"
fi
echo ""

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1

echo ""
echo "vLLM stack is operational."
echo "  Endpoint: $ENDPOINT"
