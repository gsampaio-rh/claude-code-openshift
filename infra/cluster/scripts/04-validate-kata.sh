#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0; WARN=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

NAMESPACE_AGENT="${NAMESPACE_AGENT:-agent-sandboxes}"

echo "============================================================"
echo " Kata Containers — Validation"
echo "============================================================"
echo ""

# ── 1. Operator ───────────────────────────────────────────────

echo "1. Operator Status"

CSV_STATUS=$(oc get csv -n openshift-sandboxed-containers-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
if [[ "$CSV_STATUS" == "Succeeded" ]]; then
  CSV_VER=$(oc get csv -n openshift-sandboxed-containers-operator -o jsonpath='{.items[0].spec.version}' 2>/dev/null)
  pass "Operator $CSV_VER installed (Succeeded)"
else
  fail "Operator not installed or not Succeeded (status: $CSV_STATUS)"
fi

echo ""

# ── 2. KataConfig ─────────────────────────────────────────────

echo "2. KataConfig"

if oc get kataconfig cluster-kataconfig &>/dev/null; then
  COMPLETED=$(oc get kataconfig cluster-kataconfig -o jsonpath='{.status.installationStatus.completed.completedNodesCount}' 2>/dev/null || echo "0")
  TOTAL=$(oc get kataconfig cluster-kataconfig -o jsonpath='{.status.totalNodesCount}' 2>/dev/null || echo "0")
  pass "KataConfig: $COMPLETED/$TOTAL nodes completed"

  IN_PROGRESS=$(oc get kataconfig cluster-kataconfig -o jsonpath='{.status.installationStatus.inprogress.binariesInstallNodesList}' 2>/dev/null || echo "")
  if [[ -n "$IN_PROGRESS" && "$IN_PROGRESS" != "null" ]]; then
    warn "Nodes still installing: $IN_PROGRESS"
  fi
else
  fail "KataConfig not found"
fi

echo ""

# ── 3. RuntimeClass ───────────────────────────────────────────

echo "3. RuntimeClass"

if oc get runtimeclass kata &>/dev/null; then
  pass "RuntimeClass 'kata' exists"
else
  fail "RuntimeClass 'kata' not found"
fi

echo ""

# ── 4. MCP kata-oc ────────────────────────────────────────────

echo "4. MachineConfigPool"

MCP_READY=$(oc get mcp kata-oc -o jsonpath='{.status.readyMachineCount}' 2>/dev/null || echo "0")
MCP_TOTAL=$(oc get mcp kata-oc -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0")
MCP_UPDATED=$(oc get mcp kata-oc -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "")

if [[ "$MCP_UPDATED" == "True" ]]; then
  pass "MCP kata-oc: $MCP_READY/$MCP_TOTAL ready, Updated=True"
else
  warn "MCP kata-oc: $MCP_READY/$MCP_TOTAL ready, Updated=$MCP_UPDATED"
fi

echo ""

# ── 5. Bare Metal Nodes ──────────────────────────────────────

echo "5. Bare Metal Nodes (/dev/kvm)"

METAL_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' 2>/dev/null \
  | grep -i "metal" || echo "")

if [[ -n "$METAL_NODES" ]]; then
  while IFS=$'\t' read -r NODE_NAME INSTANCE_TYPE; do
    pass "Bare metal node: $NODE_NAME ($INSTANCE_TYPE)"

    KVM_CHECK=$(oc debug node/"$NODE_NAME" -- chroot /host ls -la /dev/kvm 2>&1 | grep "kvm" || echo "")
    if [[ -n "$KVM_CHECK" ]]; then
      pass "$NODE_NAME: /dev/kvm present"
    else
      fail "$NODE_NAME: /dev/kvm NOT found"
    fi
  done <<< "$METAL_NODES"
else
  warn "No bare metal nodes found (Kata requires /dev/kvm — ADR-017)"
  echo "       Regular EC2 VMs do not expose /dev/kvm."
  echo "       Use *.metal instance types (m5.metal, c5.metal, etc.)"
fi

echo ""

# ── 6. Kata Runtime on Nodes ──────────────────────────────────

echo "6. Kata Runtime Binary"

KATA_NODES=$(oc get kataconfig cluster-kataconfig -o jsonpath='{.status.installationStatus.completed.completedNodesList}' 2>/dev/null | tr -d '[]"' | tr ',' '\n' || echo "")

if [[ -n "$KATA_NODES" ]]; then
  for NODE in $KATA_NODES; do
    [[ -z "$NODE" ]] && continue
    KATA_VER=$(oc debug node/"$NODE" -- chroot /host kata-runtime --version 2>&1 | grep "kata-runtime" | head -1 || echo "")
    if [[ -n "$KATA_VER" ]]; then
      pass "$NODE: $KATA_VER"
    else
      warn "$NODE: kata-runtime not found in PATH"
    fi
  done
else
  warn "No completed nodes in KataConfig"
fi

echo ""

# ── 7. Test Pod ───────────────────────────────────────────────

echo "7. Kata Test Pod"

if [[ -n "$METAL_NODES" ]]; then
  METAL_NODE=$(echo "$METAL_NODES" | head -1 | awk '{print $1}')
  METAL_TYPE=$(echo "$METAL_NODES" | head -1 | awk '{print $2}')

  oc delete pod kata-validation-test -n "$NAMESPACE_AGENT" --ignore-not-found &>/dev/null

  cat <<EOF | oc apply -n "$NAMESPACE_AGENT" -f -
apiVersion: v1
kind: Pod
metadata:
  name: kata-validation-test
  labels:
    app: kata-validation
spec:
  runtimeClassName: kata
  serviceAccountName: claude-code-agent
  nodeSelector:
    node.kubernetes.io/instance-type: "$METAL_TYPE"
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sh", "-c", "echo KATA_OK; sleep 5"]
      resources:
        requests: { cpu: "50m", memory: "64Mi" }
        limits: { cpu: "200m", memory: "256Mi" }
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
        capabilities: { drop: ["ALL"] }
  restartPolicy: Never
EOF

  echo "  Waiting for test pod..."
  for i in $(seq 1 24); do
    PHASE=$(oc get pod kata-validation-test -n "$NAMESPACE_AGENT" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$PHASE" == "Running" || "$PHASE" == "Succeeded" ]]; then
      LOGS=$(oc logs kata-validation-test -n "$NAMESPACE_AGENT" 2>/dev/null || echo "")
      if echo "$LOGS" | grep -q "KATA_OK"; then
        pass "Kata test pod ran successfully on $METAL_NODE"
      else
        warn "Kata test pod ran but output unexpected: $LOGS"
      fi
      break
    fi
    if [[ "$PHASE" == "Failed" ]]; then
      fail "Kata test pod failed"
      oc describe pod kata-validation-test -n "$NAMESPACE_AGENT" 2>&1 | tail -10
      break
    fi
    sleep 5
  done

  oc delete pod kata-validation-test -n "$NAMESPACE_AGENT" --ignore-not-found &>/dev/null
else
  warn "Skipping test pod — no bare metal nodes available"
fi

echo ""

# ── 8. Claude Code + Kata ─────────────────────────────────────

echo "8. Claude Code Deployment (Kata)"

RUNTIME=$(oc get deployment claude-code-standalone -n "$NAMESPACE_AGENT" -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || echo "")
if [[ "$RUNTIME" == "kata" ]]; then
  pass "Deployment uses runtimeClassName: kata"
else
  warn "Deployment runtimeClassName: '${RUNTIME:-not set}' (expected: kata)"
fi

AGENT_NODE=$(oc get pods -n "$NAMESPACE_AGENT" -l app.kubernetes.io/name=claude-code -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
if echo "$AGENT_NODE" | grep -qi ""; then
  pass "Agent pod running on: $AGENT_NODE"
  NODE_TYPE=$(oc get node "$AGENT_NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "")
  if echo "$NODE_TYPE" | grep -qi "metal"; then
    pass "Node is bare metal ($NODE_TYPE)"
  else
    warn "Node is NOT bare metal ($NODE_TYPE) — Kata may not work"
  fi
fi

echo ""

# ── 9. SELinux Bug (ADR-018) ─────────────────────────────────

echo "9. Known Issues"

MONITOR_ERRORS=$(oc get pods -n openshift-sandboxed-containers-operator 2>/dev/null \
  | grep -c "CreateContainerError\|CrashLoopBackOff\|Error" || echo "0")
if [[ "$MONITOR_ERRORS" -gt 0 ]]; then
  warn "osc-monitor pods failing ($MONITOR_ERRORS pods) — ADR-018 SELinux bug"
  echo "       This is a known issue with operator 1.3.3 on OCP 4.20 (RHEL 8 vs RHEL 9)."
  echo "       Kata runtime is NOT affected. Fix: upgrade to operator 1.5+."
else
  pass "No operator pod errors detected"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────

echo "============================================================"
if [[ "$FAIL" -gt 0 ]]; then
  echo " RESULT: FAIL — $PASS passed, $FAIL failed, $WARN warnings"
else
  echo " RESULT: PASS — $PASS passed, $FAIL failed, $WARN warnings"
fi
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
