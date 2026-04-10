#!/usr/bin/env bash
# Verify the observability stack: MLflow Tracking Server + Route.
#
# OTEL Collector, Prometheus, and Grafana are disabled — their manifests are
# kept under observability/{otel,prometheus,grafana}/ for future re-enablement.
#
# Usage: ./99-verify.sh
# Prerequisites: oc login, observability stack deployed
# Returns exit 1 if any FAIL checks; 0 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0; WARN=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
check() { local desc="$1"; shift; if "$@" &>/dev/null; then pass "$desc"; else fail "$desc"; fi; }

section() { echo ""; echo "$1"; }

echo "============================================================"
echo " Observability | MLflow Verification"
echo "============================================================"

# ── 1. Resource existence ────────────────────────────────────────

section "1. Resources"

check "Deployment 'mlflow-tracking'" \
  oc get deployment mlflow-tracking -n "$NAMESPACE"
check "Service 'mlflow-tracking'" \
  oc get service mlflow-tracking -n "$NAMESPACE"
check "PVC 'mlflow-tracking-store'" \
  oc get pvc mlflow-tracking-store -n "$NAMESPACE"

MLFLOW_HOST=$(oc get route mlflow-tracking -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$MLFLOW_HOST" ]]; then pass "Route 'mlflow-tracking' (https://$MLFLOW_HOST)"; else fail "Route 'mlflow-tracking' not found"; fi

# ── 2. Pod health ────────────────────────────────────────────────

section "2. Pod Health"

POD_COUNT=$(oc get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=mlflow-tracking" \
  --field-selector=status.phase=Running \
  -o name 2>/dev/null | wc -l | tr -d ' ')
if [[ "$POD_COUNT" -ge 1 ]]; then
  pass "mlflow-tracking running ($POD_COUNT replica(s))"
else
  fail "mlflow-tracking: no running pods"
fi

# ── 3. MLflow health endpoints ──────────────────────────────────

section "3. Health Endpoints"

MLFLOW_POD=$(oc get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=mlflow-tracking" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$MLFLOW_POD" ]]; then
  HEALTH=$(oc exec "$MLFLOW_POD" -n "$NAMESPACE" -- \
    python -c "import urllib.request; r=urllib.request.urlopen('http://localhost:5000/health'); print(r.status)" 2>/dev/null || echo "000")
  if [[ "$HEALTH" == "200" ]]; then
    pass "MLflow /health → 200"
  else
    fail "MLflow /health → $HEALTH"
  fi

  VERSION=$(oc exec "$MLFLOW_POD" -n "$NAMESPACE" -- \
    python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:5000/version').read().decode().strip())" 2>/dev/null || echo "")
  if [[ -n "$VERSION" ]]; then
    pass "MLflow API version: $VERSION"
  else
    fail "MLflow API did not respond"
  fi
else
  fail "Cannot check MLflow API — no running pod"
fi

# ── 4. MLflow experiment check ──────────────────────────────────

section "4. MLflow Experiment"

if [[ -n "$MLFLOW_POD" ]]; then
  EXP_CHECK=$(oc exec "$MLFLOW_POD" -n "$NAMESPACE" -- \
    python -c "
import urllib.request, json
req = urllib.request.Request('http://localhost:5000/api/2.0/mlflow/experiments/get-by-name?experiment_name=claude-code-agents')
try:
    resp = urllib.request.urlopen(req)
    data = json.loads(resp.read())
    print(data['experiment']['experiment_id'])
except Exception:
    print('')
" 2>/dev/null || echo "")
  if [[ -n "$EXP_CHECK" ]]; then
    pass "Experiment 'claude-code-agents' exists (id=$EXP_CHECK)"
  else
    warn "Experiment 'claude-code-agents' not found — will be created on first agent run"
  fi
else
  warn "Cannot check experiments — no running MLflow pod"
fi

# ── 5. External Route access ────────────────────────────────────

section "5. External Route Access"

if [[ -n "$MLFLOW_HOST" ]]; then
  MLFLOW_EXT=$(curl -sk -o /dev/null -w "%{http_code}" "https://$MLFLOW_HOST/health" 2>/dev/null || echo "000")
  if [[ "$MLFLOW_EXT" == "200" ]]; then
    pass "MLflow Route externally reachable (HTTP $MLFLOW_EXT)"
  else
    warn "MLflow Route returned HTTP $MLFLOW_EXT (may need VPN or DNS)"
  fi
fi

# ── Results ──────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1

echo ""
echo "Observability stack is operational."
[[ -n "${MLFLOW_HOST:-}" ]] && echo "  MLflow:  https://$MLFLOW_HOST"
