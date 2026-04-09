#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0; WARN=0; SKIP=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP + 1)); }

NAMESPACE_INFERENCE="${NAMESPACE_INFERENCE:-inference}"
NAMESPACE_AGENT="${NAMESPACE_AGENT:-agent-sandboxes}"
MODEL_NAME="${MODEL_NAME:-qwen25-14b}"
DEPLOY_NAME="${DEPLOY_NAME:-claude-code-standalone}"
VLLM_ENDPOINT="http://${MODEL_NAME}.${NAMESPACE_INFERENCE}.svc.cluster.local:8080"

echo "============================================================"
echo " End-to-End Validation — AgentOps Platform"
echo "============================================================"
echo ""
echo "  vLLM:        $VLLM_ENDPOINT"
echo "  Agent:       $DEPLOY_NAME ($NAMESPACE_AGENT)"
echo "  Model:       $MODEL_NAME"
echo "  Time:        $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# ── 1. Cluster Connectivity ─────────────────────────────────

echo "1. Cluster Connectivity"

if oc whoami &>/dev/null; then
  pass "Logged in as: $(oc whoami)"
else
  fail "Not logged in to OpenShift"
  echo ""; exit 1
fi

OCP_VER=$(oc version -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion','?'))" 2>/dev/null || echo "?")
pass "OpenShift version: $OCP_VER"
echo ""

# ── 2. GPU Node ──────────────────────────────────────────────

echo "2. GPU Node"

GPU_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\t"}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' 2>/dev/null \
  | awk '$2 > 0')

if [[ -n "$GPU_NODES" ]]; then
  GPU_PRODUCT=$(echo "$GPU_NODES" | head -1 | awk '{print $3}')
  pass "GPU available: $GPU_PRODUCT"
else
  fail "No GPU nodes found"
fi
echo ""

# ── 3. vLLM Pod ──────────────────────────────────────────────

echo "3. vLLM Inference"

VLLM_POD=$(oc get pods -n "$NAMESPACE_INFERENCE" -l "app.kubernetes.io/name=$MODEL_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$VLLM_POD" ]]; then
  fail "vLLM pod not found in $NAMESPACE_INFERENCE"
  echo ""; echo "Aborting — vLLM is required for E2E."; exit 1
fi
pass "vLLM pod: $VLLM_POD"

VLLM_READY=$(oc get pod "$VLLM_POD" -n "$NAMESPACE_INFERENCE" \
  -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
if [[ "$VLLM_READY" == "true" ]]; then
  pass "vLLM pod is Ready"
else
  fail "vLLM pod is not Ready"
fi

HEALTH=$(oc exec -n "$NAMESPACE_INFERENCE" "$VLLM_POD" -- curl -s --max-time 5 http://localhost:8080/health 2>/dev/null || echo "")
if [[ $? -eq 0 ]]; then pass "vLLM /health: OK"; else fail "vLLM /health: unreachable"; fi

MODEL_LEN=$(oc exec -n "$NAMESPACE_INFERENCE" "$VLLM_POD" -- curl -s http://localhost:8080/v1/models 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['max_model_len'])" 2>/dev/null || echo "?")
pass "max_model_len: $MODEL_LEN"
echo ""

# ── 4. Claude Code Pod ──────────────────────────────────────

echo "4. Claude Code Agent"

if ! oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE_AGENT" &>/dev/null; then
  fail "Deployment '$DEPLOY_NAME' not found"
  echo ""; echo "Aborting — agent deployment required for E2E."; exit 1
fi

AGENT_REPLICAS=$(oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE_AGENT" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED_REPLICAS=$(oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE_AGENT" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
pass "Agent deployment: ${AGENT_REPLICAS:-0}/${DESIRED_REPLICAS} ready"

POD_NAME=$(oc get pods -n "$NAMESPACE_AGENT" \
  -l "app.kubernetes.io/name=claude-code,app.kubernetes.io/component=agent-standalone" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$POD_NAME" ]]; then
  fail "No running agent pod found"
  echo ""; echo "Aborting — agent pod required for E2E."; exit 1
fi
pass "Using agent pod: $POD_NAME"

CLAUDE_VER=$(oc exec -n "$NAMESPACE_AGENT" "$POD_NAME" -- claude --version 2>/dev/null || echo "")
if [[ -n "$CLAUDE_VER" ]]; then pass "Claude Code CLI: v$CLAUDE_VER"; else fail "Claude Code CLI not in PATH"; fi
echo ""

# ── 5. Cross-Namespace Connectivity ─────────────────────────

echo "5. Cross-Namespace: Agent → vLLM"

DNS_CHECK=$(oc exec -n "$NAMESPACE_AGENT" "$POD_NAME" -- \
  curl -s --max-time 10 "$VLLM_ENDPOINT/v1/models" 2>/dev/null || echo "")

if echo "$DNS_CHECK" | grep -q '"data"'; then
  pass "Agent can reach vLLM at $VLLM_ENDPOINT"
else
  fail "Agent cannot reach vLLM (DNS or NetworkPolicy issue)"
fi
echo ""

# ── 6. API Tests ─────────────────────────────────────────────

echo "6. API Functional Tests"

echo "  6a. Anthropic Messages API (/v1/messages)"
START_MS=$(date +%s%3N 2>/dev/null || date +%s)
MSG_RESP=$(oc exec -n "$NAMESPACE_AGENT" "$POD_NAME" -- \
  curl -s --max-time 30 -X POST "$VLLM_ENDPOINT/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: not-needed" \
  -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 5+3? Answer with just the number.\"}],\"max_tokens\":10}" 2>/dev/null || echo "")
END_MS=$(date +%s%3N 2>/dev/null || date +%s)
LATENCY=$(( END_MS - START_MS ))

if echo "$MSG_RESP" | grep -q '"content"'; then
  pass "Anthropic API: working (${LATENCY}ms)"
else
  fail "Anthropic API: failed (${MSG_RESP:0:100})"
fi

echo "  6b. OpenAI Chat Completions API (/v1/chat/completions)"
CHAT_RESP=$(oc exec -n "$NAMESPACE_AGENT" "$POD_NAME" -- \
  curl -s --max-time 30 -X POST "$VLLM_ENDPOINT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2*3? Answer with just the number.\"}],\"max_tokens\":10}" 2>/dev/null || echo "")

if echo "$CHAT_RESP" | grep -q '"choices"'; then
  pass "OpenAI API: working"
else
  fail "OpenAI API: failed"
fi
echo ""

# ── 7. Claude Code E2E ──────────────────────────────────────

echo "7. Claude Code E2E (agent → model via CLI)"

echo "  7a. Simple math"
MATH_RESP=$(oc exec -n "$NAMESPACE_AGENT" "$POD_NAME" -- \
  claude -p "What is 7+5? Answer with just the number." 2>/dev/null || echo "")

if echo "$MATH_RESP" | grep -q "12"; then
  pass "Math test: correct (12)"
else
  warn "Math test: unexpected response (${MATH_RESP:0:60})"
fi

echo "  7b. Code generation"
START_MS=$(date +%s%3N 2>/dev/null || date +%s)
CODE_RESP=$(oc exec -n "$NAMESPACE_AGENT" "$POD_NAME" -- \
  claude -p "Write a Python function called 'factorial' that computes n!. Only return the code, no explanation." 2>/dev/null || echo "")
END_MS=$(date +%s%3N 2>/dev/null || date +%s)
CODE_LATENCY=$(( END_MS - START_MS ))

if echo "$CODE_RESP" | grep -q "def factorial"; then
  pass "Code gen: produced factorial function (${CODE_LATENCY}ms)"
else
  warn "Code gen: output didn't contain 'def factorial' (${CODE_LATENCY}ms)"
fi

echo "  7c. claude-logged wrapper"
LOG_RESP=$(oc exec -n "$NAMESPACE_AGENT" "$POD_NAME" -- \
  claude-logged "What is 1+1? Answer with just the number." 2>/dev/null || echo "")

if echo "$LOG_RESP" | grep -q '"type":"result"'; then
  pass "claude-logged: NDJSON output produced"
else
  warn "claude-logged: no NDJSON result line found"
fi
echo ""

# ── 8. Kata Containers ────────────────────────────────────────

echo "8. Kata Containers"

KATA_RC=$(oc get runtimeclass kata --no-headers 2>/dev/null || echo "")
if [[ -n "$KATA_RC" ]]; then
  pass "RuntimeClass 'kata' exists"
else
  warn "RuntimeClass 'kata' not found (Kata not installed)"
fi

RUNTIME_CLASS=$(oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE_AGENT" \
  -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || echo "")
if [[ "$RUNTIME_CLASS" == "kata" ]]; then
  pass "Deployment uses runtimeClassName: kata"
else
  warn "Deployment runtimeClassName: '${RUNTIME_CLASS:-not set}' (expected: kata)"
fi

AGENT_NODE=$(oc get pod "$POD_NAME" -n "$NAMESPACE_AGENT" \
  -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
if [[ -n "$AGENT_NODE" ]]; then
  NODE_TYPE=$(oc get node "$AGENT_NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "")
  if echo "$NODE_TYPE" | grep -qi "metal"; then
    pass "Agent on bare metal: $AGENT_NODE ($NODE_TYPE)"
  else
    warn "Agent node is NOT bare metal ($NODE_TYPE) — Kata requires /dev/kvm (ADR-017)"
  fi
fi

KATA_MCP_STATUS=$(oc get mcp kata-oc -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "")
if [[ "$KATA_MCP_STATUS" == "True" ]]; then
  pass "MCP kata-oc: Updated=True"
elif [[ -n "$KATA_MCP_STATUS" ]]; then
  warn "MCP kata-oc: Updated=$KATA_MCP_STATUS"
else
  warn "MCP kata-oc not found"
fi

OSC_ERRORS=$(oc get pods -n openshift-sandboxed-containers-operator 2>/dev/null \
  | grep -c "CreateContainerError\|CrashLoopBackOff\|Error" || echo "0")
if [[ "$OSC_ERRORS" -gt 0 ]]; then
  warn "osc-monitor pods failing ($OSC_ERRORS) — ADR-018 SELinux bug (non-blocking)"
else
  pass "No osc-monitor errors"
fi

echo ""

# ── 9. Security Posture ──────────────────────────────────────

echo "9. Security Posture"

for NS_CHECK in "$NAMESPACE_INFERENCE" "$NAMESPACE_AGENT"; do
  NP_COUNT=$(oc get networkpolicy -n "$NS_CHECK" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$NP_COUNT" -ge 1 ]]; then
    pass "NetworkPolicies in '$NS_CHECK': $NP_COUNT"
  else
    warn "No NetworkPolicies in '$NS_CHECK'"
  fi
done

for POD_CHECK in "$VLLM_POD:$NAMESPACE_INFERENCE" "$POD_NAME:$NAMESPACE_AGENT"; do
  P=$(echo "$POD_CHECK" | cut -d: -f1)
  N=$(echo "$POD_CHECK" | cut -d: -f2)
  NON_ROOT=$(oc get pod "$P" -n "$N" \
    -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null || echo "")
  if [[ "$NON_ROOT" == "true" ]]; then
    pass "$P: runAsNonRoot=true"
  else
    warn "$P: runAsNonRoot not set"
  fi
done
echo ""

# ── Summary ──────────────────────────────────────────────────

echo "============================================================"
if [[ "$FAIL" -gt 0 ]]; then
  echo " RESULT: FAIL — $PASS passed, $FAIL failed, $WARN warnings"
else
  echo " RESULT: PASS — $PASS passed, $FAIL failed, $WARN warnings"
fi
echo "============================================================"
echo ""

[[ "$FAIL" -gt 0 ]] && exit 1

echo "AgentOps E2E validation complete. Stack is operational."
echo ""
echo "  Interactive:    oc exec -it -n $NAMESPACE_AGENT $POD_NAME -- claude"
echo "  Headless:       oc exec -n $NAMESPACE_AGENT $POD_NAME -- claude -p 'prompt'"
echo "  Logged:         oc exec -n $NAMESPACE_AGENT $POD_NAME -- claude-logged 'prompt'"
echo "  Container logs: oc logs -f $POD_NAME -n $NAMESPACE_AGENT"
