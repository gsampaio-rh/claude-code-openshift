#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

OPERATORS_DIR="$(cd "$SCRIPT_DIR/../operators" && pwd)"

echo "============================================================"
echo " Kata Containers — Install & Configure"
echo "============================================================"
echo ""

# ── 1. Install Sandboxed Containers Operator ──────────────────

echo "1. Sandboxed Containers Operator"

if oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null | grep -q "Succeeded"; then
  echo "  [SKIP] Operator already installed"
else
  echo "  Applying $OPERATORS_DIR/sandboxed-containers.yaml"
  oc apply -f "$OPERATORS_DIR/sandboxed-containers.yaml"

  echo "  Waiting for operator CSV to reach Succeeded..."
  for i in $(seq 1 30); do
    if oc get csv -n openshift-sandboxed-containers-operator 2>/dev/null | grep -q "Succeeded"; then
      echo "  [PASS] Operator installed"
      break
    fi
    sleep 10
  done
fi

echo ""

# ── 2. Wait for controller-manager ───────────────────────────

echo "2. Controller Manager"

oc wait pod -n openshift-sandboxed-containers-operator \
  -l control-plane=controller-manager \
  --for=condition=Ready \
  --timeout=120s 2>/dev/null && echo "  [PASS] Controller-manager ready" \
  || echo "  [WARN] Controller-manager not ready (webhook may fail)"

echo ""

# ── 3. Create KataConfig ─────────────────────────────────────

echo "3. KataConfig"

if oc get kataconfig cluster-kataconfig &>/dev/null; then
  echo "  [SKIP] KataConfig already exists"
else
  echo "  Applying $OPERATORS_DIR/kataconfig.yaml"
  for i in $(seq 1 5); do
    if oc apply -f "$OPERATORS_DIR/kataconfig.yaml" 2>/dev/null; then
      echo "  [PASS] KataConfig created"
      break
    fi
    echo "  Attempt $i/5 failed (webhook not ready), retrying in 15s..."
    sleep 15
  done
fi

echo ""

# ── 4. Wait for MCP kata-oc ──────────────────────────────────

echo "4. MachineConfigPool kata-oc"

echo "  Waiting for MCP update (nodes will reboot)..."
for i in $(seq 1 60); do
  UPDATED=$(oc get mcp kata-oc -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null)
  UPDATING=$(oc get mcp kata-oc -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null)
  DEGRADED=$(oc get mcp kata-oc -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null)
  READY=$(oc get mcp kata-oc -o jsonpath='{.status.readyMachineCount}' 2>/dev/null)
  TOTAL=$(oc get mcp kata-oc -o jsonpath='{.status.machineCount}' 2>/dev/null)

  if [[ "$DEGRADED" == "True" ]]; then
    echo "  [FAIL] MCP degraded"
    oc get mcp kata-oc -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null
    exit 1
  fi

  if [[ "$UPDATED" == "True" && "$UPDATING" == "False" ]]; then
    echo "  [PASS] MCP kata-oc: $READY/$TOTAL ready"
    break
  fi

  echo "  [$((i*15))s] Updated=$UPDATED Updating=$UPDATING Ready=${READY:-0}/${TOTAL:-?}"
  sleep 15
done

echo ""

# ── 5. Verify RuntimeClass ───────────────────────────────────

echo "5. RuntimeClass"

if oc get runtimeclass kata &>/dev/null; then
  echo "  [PASS] RuntimeClass 'kata' exists"
else
  echo "  [FAIL] RuntimeClass 'kata' not found"
  exit 1
fi

echo ""

# ── 6. Summary ────────────────────────────────────────────────

echo "============================================================"
echo " Kata installation complete"
echo "============================================================"
echo ""
echo "  Operator:      $(oc get csv -n openshift-sandboxed-containers-operator -o jsonpath='{.items[0].spec.version}' 2>/dev/null)"
echo "  RuntimeClass:  kata"
echo "  MCP:           kata-oc ($(oc get mcp kata-oc -o jsonpath='{.status.readyMachineCount}' 2>/dev/null)/$(oc get mcp kata-oc -o jsonpath='{.status.machineCount}' 2>/dev/null) ready)"
echo ""
echo "  Manifests:"
echo "    $OPERATORS_DIR/sandboxed-containers.yaml"
echo "    $OPERATORS_DIR/kataconfig.yaml"
echo ""
echo "  IMPORTANT: Kata requires /dev/kvm — only bare metal nodes support it."
echo "  See ADR-017 for details."
echo ""
echo "  Known issue: osc-monitor pods may fail with SELinux error on OCP 4.20"
echo "  (operator 1.3.3 uses RHEL 8 images). See ADR-018."
echo ""
echo "  Next: Run 04-validate-kata.sh to test Kata on a bare metal node."
