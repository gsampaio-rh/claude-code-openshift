#!/usr/bin/env bash
# Deploy the observability stack: MLflow Tracking Server.
#
# OTEL Collector, Prometheus, and Grafana are disabled for now.
# Their manifests are kept under observability/{otel,prometheus,grafana}/ for
# future re-enablement but are not deployed by this script.
#
# Usage: ./01-deploy-observability.sh
# Prerequisites: oc login, namespace 'observability' exists
# Override settings via .env or environment variables (see config.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Observability | Deploy MLflow Tracking Server"
echo "============================================================"
echo ""

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi
echo "Logged in as: $(oc whoami)"
echo ""

if ! oc get namespace "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Namespace '$NAMESPACE' not found."
  echo "Run cluster setup first: infra/cluster/scripts/01-setup-cluster.sh"
  exit 1
fi

echo "Deploying MLflow PVC..."
oc apply -n "$NAMESPACE" -f "$MLFLOW_MANIFESTS_DIR/pvc.yaml"
echo ""

echo "Deploying MLflow Tracking Server..."
oc apply -n "$NAMESPACE" -f "$MLFLOW_MANIFESTS_DIR/deployment.yaml"
oc apply -n "$NAMESPACE" -f "$MLFLOW_MANIFESTS_DIR/service.yaml"
echo ""

echo "Waiting for MLflow pod (timeout: $OBSERVABILITY_READY_TIMEOUT)..."
oc wait --for=condition=Available \
  deployment/mlflow-tracking \
  -n "$NAMESPACE" \
  --timeout="$OBSERVABILITY_READY_TIMEOUT"
echo ""

echo "Deploying MLflow Route..."
oc apply -n "$NAMESPACE" -f "$MLFLOW_MANIFESTS_DIR/route.yaml"
echo ""

# Create default experiment so the first agent doesn't have to
MLFLOW_POD=$(oc get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=mlflow-tracking" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$MLFLOW_POD" ]]; then
  echo "Creating default MLflow experiment 'claude-code-agents'..."
  oc exec "$MLFLOW_POD" -n "$NAMESPACE" -- \
    python -c "
import urllib.request, urllib.error, json
req = urllib.request.Request(
    'http://localhost:5000/api/2.0/mlflow/experiments/create',
    data=json.dumps({'name': 'claude-code-agents'}).encode(),
    headers={'Content-Type': 'application/json'},
    method='POST')
try:
    resp = urllib.request.urlopen(req)
    data = json.loads(resp.read())
    print(f\"  Experiment created (id={data['experiment_id']}).\")
except urllib.error.HTTPError as e:
    body = e.read().decode()
    if 'RESOURCE_ALREADY_EXISTS' in body:
        print('  Experiment already exists — OK.')
    else:
        print(f'  Warning: {e.code} {body[:120]}')
" 2>/dev/null || echo "  Warning: could not create experiment (MLflow may still be starting)."
  echo ""
fi

MLFLOW_HOST=$(oc get route mlflow-tracking -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

echo "Observability stack deployed."
echo ""
echo "Endpoints (cluster-internal):"
echo "  MLflow:     ${MLFLOW_ENDPOINT}"
echo ""
echo "Routes (external):"
echo "  MLflow UI:  https://${MLFLOW_HOST}"
echo ""
echo "Next: verify:"
echo "  ./99-verify.sh"
