#!/usr/bin/env bash
# Claude Code Agent Configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$AGENTS_DIR/.." && pwd)"
MANIFESTS_DIR="$(cd "$AGENTS_DIR/claude-code/manifests" && pwd)"
DOCKERFILE_DIR="$(cd "$AGENTS_DIR/claude-code" && pwd)"

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
  set +a
fi

export NAMESPACE="${NAMESPACE_AGENT_SANDBOXES:-agent-sandboxes}"
export NAMESPACE_INFERENCE="${NAMESPACE_INFERENCE:-inference}"
export MODEL_NAME="${MODEL_NAME:-qwen25-14b}"
export DEPLOY_NAME="claude-code-standalone"
export BUILD_NAME="claude-code-agent"
export CLAUDE_CODE_AGENT_IMAGE="${CLAUDE_CODE_AGENT_IMAGE:-image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/${BUILD_NAME}:latest}"
export VLLM_ENDPOINT="http://${MODEL_NAME}.${NAMESPACE_INFERENCE}.svc.cluster.local:8080"
