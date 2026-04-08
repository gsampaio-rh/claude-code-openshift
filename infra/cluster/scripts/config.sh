#!/usr/bin/env bash
# Cluster setup configuration
# Loads values from the project-root .env file, with sensible defaults.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../namespaces" && pwd)"
OPERATORS_DIR="$(cd "$SCRIPT_DIR/../operators" && pwd)"

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
  set +a
fi

export NAMESPACE_INFERENCE="${NAMESPACE_INFERENCE:-inference}"
export NAMESPACE_AGENT_SANDBOXES="${NAMESPACE_AGENT_SANDBOXES:-agent-sandboxes}"
export NAMESPACE_CODER="${NAMESPACE_CODER:-coder}"
export NAMESPACE_AGENTOPS="${NAMESPACE_AGENTOPS:-agentops}"
export NAMESPACE_MCP_GATEWAY="${NAMESPACE_MCP_GATEWAY:-mcp-gateway}"
export NAMESPACE_OBSERVABILITY="${NAMESPACE_OBSERVABILITY:-observability}"
export NAMESPACE_CICD="${NAMESPACE_CICD:-cicd}"
