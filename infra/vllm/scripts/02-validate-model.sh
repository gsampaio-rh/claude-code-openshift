#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0; WARN=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

exec_curl() {
  local pod_name="$1"; shift
  oc exec -n "$NAMESPACE" "$pod_name" -- curl -s --max-time 30 "$@" 2>/dev/null
}

echo "============================================================"
echo " vLLM | Validation — $MODEL_NAME"
echo "============================================================"
echo ""
echo "  Image:    $VLLM_IMAGE"
echo "  Endpoint: $VLLM_ENDPOINT"
echo ""

# ── 1. Cluster & Deployment ──────────────────────────────────

echo "1. Cluster & Deployment"

if oc whoami &>/dev/null; then pass "oc CLI is logged in"; else fail "oc CLI not logged in"; fi

if oc get namespace "$NAMESPACE" &>/dev/null; then
  pass "Namespace '$NAMESPACE' exists"
else
  fail "Namespace '$NAMESPACE' missing"; echo ""; exit 1
fi

if oc get deployment "$MODEL_NAME" -n "$NAMESPACE" &>/dev/null; then
  pass "Deployment '$MODEL_NAME' exists"
else
  fail "Deployment '$MODEL_NAME' missing"; echo ""; exit 1
fi

if oc get service "$MODEL_NAME" -n "$NAMESPACE" &>/dev/null; then
  pass "Service '$MODEL_NAME' exists"
else
  fail "Service '$MODEL_NAME' missing"
fi

READY_REPLICAS=$(oc get deployment "$MODEL_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${READY_REPLICAS:-0}" -ge 1 ]]; then
  pass "Deployment has $READY_REPLICAS ready replica(s)"
else
  fail "Deployment has 0 ready replicas"
fi

echo ""

# ── 2. Pod Health ────────────────────────────────────────────

echo "2. Pod Health"

POD_NAME=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$MODEL_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$POD_NAME" ]]; then
  fail "No vLLM pod found"
  echo ""
  echo "============================================================"
  echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
  echo "============================================================"
  exit 1
fi
pass "Pod found: $POD_NAME"

POD_PHASE=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
if [[ "$POD_PHASE" == "Running" ]]; then pass "Pod phase: Running"; else fail "Pod phase: $POD_PHASE"; fi

RESTART_COUNT=$(oc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
if [[ "$RESTART_COUNT" -eq 0 ]]; then
  pass "Zero restarts"
else
  warn "Pod has $RESTART_COUNT restart(s)"
fi

GPU_ALLOC=$(oc get pod "$POD_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].resources.limits.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [[ "${GPU_ALLOC:-0}" -ge 1 ]]; then
  pass "GPU allocated: ${GPU_ALLOC}x"
else
  fail "No GPU allocated"
fi

HEALTH=$(exec_curl "$POD_NAME" http://localhost:8080/health)
if [[ $? -eq 0 ]]; then pass "Health endpoint: OK"; else fail "Health endpoint: unreachable"; fi

echo ""

# ── 3. API Routes ────────────────────────────────────────────

echo "3. API Routes (Claude Code compatibility)"

MODELS_RESP=$(exec_curl "$POD_NAME" http://localhost:8080/v1/models)
if echo "$MODELS_RESP" | grep -q "$MODEL_NAME"; then
  pass "/v1/models lists '$MODEL_NAME'"
else
  fail "/v1/models does not list '$MODEL_NAME'"
fi

VERSION_RESP=$(exec_curl "$POD_NAME" http://localhost:8080/version)
if echo "$VERSION_RESP" | grep -q "version"; then
  VLLM_VER=$(echo "$VERSION_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
  pass "vLLM version: $VLLM_VER"
else
  warn "Could not retrieve vLLM version"
fi

MESSAGES_RESP=$(exec_curl "$POD_NAME" -X POST http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: not-needed" \
  -H "anthropic-version: 2023-06-01" \
  -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":10}")

if echo "$MESSAGES_RESP" | grep -q '"content"'; then
  pass "/v1/messages (Anthropic Messages API): working"
else
  fail "/v1/messages (Anthropic Messages API): broken (${MESSAGES_RESP:0:120})"
fi

CHAT_RESP=$(exec_curl "$POD_NAME" -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":10}")

if echo "$CHAT_RESP" | grep -q '"choices"'; then
  pass "/v1/chat/completions (OpenAI API): working"
else
  fail "/v1/chat/completions (OpenAI API): broken (${CHAT_RESP:0:120})"
fi

echo ""

# ── 4. Functional: Coding Task ───────────────────────────────

echo "4. Functional: Coding Task"

CODE_RESP=$(exec_curl "$POD_NAME" -X POST http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: not-needed" \
  -H "anthropic-version: 2023-06-01" \
  -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a Python function that returns the nth Fibonacci number. Only return the code.\"}],\"max_tokens\":300}")

if echo "$CODE_RESP" | grep -q "def "; then
  pass "Model generated Python code via Anthropic API"
else
  warn "Model response did not contain Python function (may still be valid)"
fi

CODE_RESP_OAI=$(exec_curl "$POD_NAME" -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2? Answer with just the number.\"}],\"max_tokens\":10}")

if echo "$CODE_RESP_OAI" | grep -q "4"; then
  pass "Model answered correctly via OpenAI API"
else
  warn "Model response unexpected via OpenAI API"
fi

echo ""

# ── 5. Security Context ─────────────────────────────────────

echo "5. Security Context"

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

# ── Summary ──────────────────────────────────────────────────

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1

echo ""
echo "vLLM stack is operational."
echo "  Anthropic API: $VLLM_ENDPOINT/v1/messages"
echo "  OpenAI API:    $VLLM_ENDPOINT/v1/chat/completions"
echo "  Health:        $VLLM_ENDPOINT/health"
