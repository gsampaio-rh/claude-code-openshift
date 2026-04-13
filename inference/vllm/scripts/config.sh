#!/usr/bin/env bash
# vLLM Model Serving Configuration
# Adapted from ~/redhat/iac/model-serving/scripts/config.sh

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
export MODEL_HF_URI="${MODEL_HF_URI:-hf://RedHatAI/Qwen2.5-14B-Instruct-FP8-dynamic}"
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
export TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-hermes}"
export GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
export GPU_COUNT="${GPU_COUNT:-1}"
export VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.19.0}"
export MODEL_READY_TIMEOUT="${MODEL_READY_TIMEOUT:-600s}"
export VLLM_ENDPOINT="http://${MODEL_NAME}.${NAMESPACE}.svc.cluster.local:8080"
