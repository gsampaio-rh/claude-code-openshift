#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

IMAGE="${CLAUDE_CODE_AGENT_IMAGE:-quay.io/agentops/claude-code-agent:latest}"
DOCKERFILE="$SCRIPT_DIR/../Dockerfile"
CONTEXT="$SCRIPT_DIR/.."

echo "============================================================"
echo " Claude Code | Build Agent Image"
echo "============================================================"
echo ""
echo "  Image:      $IMAGE"
echo "  Dockerfile: $DOCKERFILE"
echo ""

echo "── Building image ──"
podman build -t "$IMAGE" -f "$DOCKERFILE" "$CONTEXT"
echo ""

echo "── Pushing image ──"
podman push "$IMAGE"
echo ""

echo "Image pushed: $IMAGE"
echo ""
echo "Next: deploy the standalone agent:"
echo "  ./01-deploy-standalone.sh"
