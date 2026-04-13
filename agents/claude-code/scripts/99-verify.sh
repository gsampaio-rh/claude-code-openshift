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

# ── 1. Deployment Status ─────────────────────────────────────

echo "1. Deployment Status"

if oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE" &>/dev/null; then
  pass "Deployment '$DEPLOY_NAME' exists"
else
  fail "Deployment '$DEPLOY_NAME' not found"
  echo ""; exit 1
fi

DESIRED=$(oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
READY_REPLICAS=$(oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${READY_REPLICAS:-0}" -ge 1 ]]; then
  pass "Ready replicas: ${READY_REPLICAS}/${DESIRED}"
else
  fail "No ready replicas (${READY_REPLICAS:-0}/${DESIRED})"
fi

POD_NAME=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=claude-code,app.kubernetes.io/component=agent-standalone" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$POD_NAME" ]]; then
  fail "No running Claude Code pod found"
  echo ""
  echo "============================================================"
  echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
  echo "============================================================"
  exit 1
fi
pass "Using pod: $POD_NAME"

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

# ── 7. Multi-Agent ───────────────────────────────────────────

echo "7. Multi-Agent Status"

ALL_PODS=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=claude-code,app.kubernetes.io/component=agent-standalone" \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
RUNNING_PODS=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=claude-code,app.kubernetes.io/component=agent-standalone" \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

pass "Total pods: $ALL_PODS, Running: $RUNNING_PODS"

if [[ "$RUNNING_PODS" -eq "$DESIRED" ]]; then
  pass "All desired replicas are running ($RUNNING_PODS/$DESIRED)"
else
  warn "Not all replicas running ($RUNNING_PODS/$DESIRED)"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1

echo ""
echo "Agent standalone is operational ($RUNNING_PODS replica(s))."
echo ""
echo "  Interactive:  oc exec -it -n $NAMESPACE $POD_NAME -- claude"
echo "  Headless:     oc exec -n $NAMESPACE $POD_NAME -- claude -p 'your prompt'"
echo "  Logged:       oc exec -n $NAMESPACE $POD_NAME -- claude-logged 'your prompt'"
echo "  Scale:        oc scale deployment/$DEPLOY_NAME -n $NAMESPACE --replicas=N"
