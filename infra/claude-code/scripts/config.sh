#!/usr/bin/env bash
# Claude Code Agent Configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../manifests" && pwd)"

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
  set +a
fi

export NAMESPACE="${NAMESPACE_AGENT_SANDBOXES:-agent-sandboxes}"
export NAMESPACE_INFERENCE="${NAMESPACE_INFERENCE:-inference}"
export MODEL_NAME="${MODEL_NAME:-qwen25-14b}"
export POD_NAME="claude-code-standalone"
export CLAUDE_CODE_AGENT_IMAGE="${CLAUDE_CODE_AGENT_IMAGE:-quay.io/agentops/claude-code-agent:latest}"
