#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " vLLM | Cleanup"
echo "============================================================"
echo ""
echo "Removes InferenceService, ServingRuntime, Secret for '$MODEL_NAME'."
echo "Namespace is NOT deleted."
echo ""

read -rp "Continue? (y/N) " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "Aborted." && exit 0

echo ""
oc delete inferenceservice "$MODEL_NAME" -n "$NAMESPACE" --ignore-not-found
oc delete servingruntime "$MODEL_NAME" -n "$NAMESPACE" --ignore-not-found
oc delete secret "$MODEL_NAME" -n "$NAMESPACE" --ignore-not-found

echo ""
echo "Waiting for pods to terminate..."
sleep 10
echo "Cleanup complete."
