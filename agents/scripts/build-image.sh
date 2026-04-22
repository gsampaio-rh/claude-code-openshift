#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================================"
echo " Claude Code | Build Agent Image (in-cluster)"
echo "============================================================"
echo ""
echo "  Build:     $BUILD_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Image:     $CLAUDE_CODE_AGENT_IMAGE"
echo ""

if ! oc get bc "$BUILD_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "── Creating BuildConfig ──"
  oc new-build --binary \
    --name="$BUILD_NAME" \
    --to="$BUILD_NAME:latest" \
    -n "$NAMESPACE" \
    --strategy=docker
  echo ""

  echo "── Patching BuildConfig with resource limits ──"
  oc patch "bc/$BUILD_NAME" -n "$NAMESPACE" -p \
    '{"spec":{"resources":{"requests":{"cpu":"500m","memory":"1Gi"},"limits":{"cpu":"2","memory":"4Gi"}}}}'
  echo ""
fi

echo "── Starting build ──"
oc start-build "$BUILD_NAME" \
  --from-dir="$DOCKERFILE_DIR" \
  -n "$NAMESPACE" \
  --follow

echo ""
echo "Image built and pushed to internal registry."
echo "  $CLAUDE_CODE_AGENT_IMAGE"
echo ""
echo "Next: deploy the standalone agent:"
echo "  ./01-deploy-standalone.sh"
