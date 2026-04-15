#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Claude Code | Step 1: Deploy Standalone Agent"
echo "============================================================"
echo ""

echo "── Applying ConfigMap ──"
oc apply -f "$MANIFESTS_DIR/configmap.yaml"
echo ""

echo "── Deploying standalone Deployment (with claude-devtools sidecar) ──"
oc apply -f "$MANIFESTS_DIR/standalone-pod.yaml"
echo ""

DEVTOOLS_DIR="$(cd "$SCRIPT_DIR/../claude-devtools/manifests" && pwd)"
echo "── Deploying DevTools Service + Route ──"
oc apply -f "$DEVTOOLS_DIR/service.yaml"
oc apply -f "$DEVTOOLS_DIR/route.yaml"
echo ""

echo "── Waiting for rollout ──"
oc rollout status deployment/"$DEPLOY_NAME" -n "$NAMESPACE" --timeout=120s
echo ""

echo "── Verifying Claude Code CLI ──"
POD_NAME=$(oc get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=claude-code,app.kubernetes.io/component=agent-standalone" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
oc exec -n "$NAMESPACE" "$POD_NAME" -c claude-code -- claude --version
echo ""

REPLICAS=$(oc get deployment "$DEPLOY_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
DEVTOOLS_HOST=$(oc get route claude-devtools -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "pending")

echo "Standalone agent is ready ($REPLICAS replica(s))."
echo ""
echo "  To interact with a specific pod:"
echo "    oc exec -it -n $NAMESPACE $POD_NAME -c claude-code -- claude"
echo ""
echo "  Headless mode:"
echo "    oc exec -n $NAMESPACE $POD_NAME -c claude-code -- claude -p 'Write a fibonacci function in Python'"
echo ""
echo "  Scale to N agents:"
echo "    oc scale deployment/$DEPLOY_NAME -n $NAMESPACE --replicas=N"
echo ""
echo "  DevTools UI:"
echo "    https://$DEVTOOLS_HOST"
echo ""
echo "Next: verify connectivity to vLLM:"
echo "  ./99-verify.sh"
