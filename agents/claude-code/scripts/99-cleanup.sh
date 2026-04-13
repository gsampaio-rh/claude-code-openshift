#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Claude Code | Cleanup"
echo "============================================================"
echo ""
echo "Removes standalone Deployment and ConfigMap."
echo ""

read -rp "Continue? (y/N) " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && exit 0

echo ""
oc delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found
oc delete configmap claude-code-config -n "$NAMESPACE" --ignore-not-found

echo ""
echo "Waiting for pods to terminate..."
oc wait --for=delete pod -l "app.kubernetes.io/name=claude-code,app.kubernetes.io/component=agent-standalone" \
  -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

echo ""
echo "Cleanup complete."
