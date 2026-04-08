#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0; WARN=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

echo "============================================================"
echo " Claude Code | Verification"
echo "============================================================"
echo ""

# ── 1. Pod Status ─────────────────────────────────────────────

echo "1. Pod Status"

if oc get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
  pass "Pod '$POD_NAME' exists"
else
  fail "Pod '$POD_NAME' not found"
  echo ""; exit 1
fi

POD_PHASE=$(oc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [[ "$POD_PHASE" == "Running" ]]; then
  pass "Pod is Running"
else
  fail "Pod is not Running (phase: ${POD_PHASE:-unknown})"
fi

RESTART_COUNT=$(oc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [[ "$RESTART_COUNT" -eq 0 ]]; then
  pass "Zero restarts"
else
  warn "Pod has $RESTART_COUNT restart(s)"
fi
echo ""

# ── 2. Claude Code CLI ───────────────────────────────────────

echo "2. Claude Code CLI"

CLAUDE_VERSION=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- \
  claude --version 2>/dev/null || echo "")
if [[ -n "$CLAUDE_VERSION" ]]; then
  pass "Claude Code CLI installed ($CLAUDE_VERSION)"
else
  fail "Claude Code CLI not found in PATH"
fi
echo ""

# ── 3. Environment ───────────────────────────────────────────

echo "3. Environment Variables"

for VAR in ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_AUTH_TOKEN \
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_MAX_OUTPUT_TOKENS; do
  VAL=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- printenv "$VAR" 2>/dev/null || echo "")
  if [[ -n "$VAL" ]]; then
    pass "$VAR = $VAL"
  else
    fail "$VAR is not set"
  fi
done
echo ""

# ── 4. Connectivity to vLLM ──────────────────────────────────

echo "4. Connectivity to vLLM"

MODELS_RESP=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- \
  curl -s --max-time 10 "$VLLM_ENDPOINT/v1/models" 2>/dev/null || echo "")
if echo "$MODELS_RESP" | grep -q '"data"'; then
  pass "Can reach vLLM /v1/models"
else
  fail "Cannot reach vLLM at $VLLM_ENDPOINT/v1/models"
fi
echo ""

# ── 5. End-to-End: Claude Code → vLLM ────────────────────────

echo "5. End-to-End Test"

E2E_RESP=$(oc exec -n "$NAMESPACE" "$POD_NAME" -- \
  claude -p "What is 3+4? Answer with just the number." 2>/dev/null || echo "")
if echo "$E2E_RESP" | grep -q "7"; then
  pass "Claude Code e2e: math question answered correctly"
else
  warn "Claude Code e2e: unexpected response (${E2E_RESP:0:80})"
fi
echo ""

# ── 6. Security Context ──────────────────────────────────────

echo "6. Security Context"

PRIV_ESC=$(oc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null)
if [[ "$PRIV_ESC" == "false" ]]; then
  pass "allowPrivilegeEscalation: false"
else
  warn "allowPrivilegeEscalation not explicitly false"
fi

RUN_NON_ROOT=$(oc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null)
if [[ "$RUN_NON_ROOT" == "true" ]]; then
  pass "runAsNonRoot: true"
else
  warn "runAsNonRoot not set"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1

echo ""
echo "Agent standalone is operational."
echo ""
echo "  Interactive:  oc exec -it -n $NAMESPACE $POD_NAME -- claude"
echo "  Headless:     oc exec -n $NAMESPACE $POD_NAME -- claude -p 'your prompt'"
