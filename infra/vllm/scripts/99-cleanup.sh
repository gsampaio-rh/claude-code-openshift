#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " vLLM | Cleanup"
echo "============================================================"
echo ""
echo "Removes Deployment, Service, and PVC for '$MODEL_NAME'."
echo "Namespace is NOT deleted."
echo ""

read -rp "Continue? (y/N) " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && exit 0

echo ""
echo "Deleting kustomize resources..."
oc delete -k "$MANIFESTS_DIR" -n "$NAMESPACE" --ignore-not-found

echo ""
echo "Waiting for pods to terminate..."
oc wait --for=delete pod -l app.kubernetes.io/name="$MODEL_NAME" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

echo ""
echo "Remaining resources in '$NAMESPACE':"
oc get all,pvc -n "$NAMESPACE" 2>/dev/null || true
echo ""
echo "Cleanup complete."
