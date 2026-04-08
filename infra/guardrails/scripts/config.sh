#!/usr/bin/env bash
# TrustyAI Guardrails Configuration
# Adapted from ~/redhat/iac/trustyai-guardrails/scripts/config.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../manifests" && pwd)"

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
  set +a
fi

export NAMESPACE="${NAMESPACE_INFERENCE:-inference}"
export MODEL_NAME="${MODEL_NAME:-qwen25-14b}"
export MODEL_PORT="${MODEL_PORT:-8080}"
export ORCHESTRATOR_NAME="${ORCHESTRATOR_NAME:-guardrails-orchestrator}"
export ORCHESTRATOR_REPLICAS="${ORCHESTRATOR_REPLICAS:-1}"
export ORCHESTRATOR_CONFIG_NAME="${ORCHESTRATOR_CONFIG_NAME:-orchestrator-config}"
export GATEWAY_CONFIG_NAME="${GATEWAY_CONFIG_NAME:-gateway-config}"
export ORCHESTRATOR_READY_TIMEOUT="${ORCHESTRATOR_READY_TIMEOUT:-300s}"
