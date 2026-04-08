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
echo " Claude Code | Verification"
echo "============================================================"
echo ""

echo "Pod status"
check "Pod '$POD_NAME' exists" oc get pod "$POD_NAME" -n "$NAMESPACE"

POD_PHASE=$(oc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$POD_PHASE" == "Running" ]]; then
  pass "Pod is Running"
else
  fail "Pod is not Running (phase: ${POD_PHASE:-unknown})"
fi
echo ""

echo "Claude Code CLI"
CLAUDE_VERSION=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- \
  claude --version 2>/dev/null || echo "")
if [[ -n "$CLAUDE_VERSION" ]]; then
  pass "Claude Code CLI installed ($CLAUDE_VERSION)"
else
  fail "Claude Code CLI not found"
fi
echo ""

echo "Environment"
BASE_URL=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- \
  printenv ANTHROPIC_BASE_URL 2>/dev/null || echo "")
if [[ -n "$BASE_URL" ]]; then
  pass "ANTHROPIC_BASE_URL is set ($BASE_URL)"
else
  fail "ANTHROPIC_BASE_URL is not set"
fi

MODEL=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- \
  printenv ANTHROPIC_DEFAULT_SONNET_MODEL 2>/dev/null || echo "")
if [[ -n "$MODEL" ]]; then
  pass "ANTHROPIC_DEFAULT_SONNET_MODEL is set ($MODEL)"
else
  fail "ANTHROPIC_DEFAULT_SONNET_MODEL is not set"
fi
echo ""

echo "Connectivity to vLLM"
VLLM_RESULT=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- \
  curl -s "http://${MODEL_NAME}-predictor.${NAMESPACE_INFERENCE}.svc.cluster.local:8080/v1/models" \
  2>/dev/null || echo "")
if echo "$VLLM_RESULT" | grep -q '"data"'; then
  pass "Can reach vLLM /v1/models endpoint"
else
  warn "Cannot reach vLLM (may need NetworkPolicy adjustment)"
fi
echo ""

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1

echo ""
echo "Agent standalone is operational."
echo ""
echo "  Interactive:  oc exec -it -n $NAMESPACE $POD_NAME -- bash"
echo "  Headless:     oc exec -n $NAMESPACE $POD_NAME -- claude --headless 'your prompt'"
