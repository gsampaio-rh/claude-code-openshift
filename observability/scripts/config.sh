#!/usr/bin/env bash
# Observability Stack Configuration
# Sourced by deploy and verify scripts. Not meant to be run directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MLFLOW_MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../mlflow" && pwd)"

# Disabled components — manifests kept for future re-enablement.
# OTEL_MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../otel" && pwd)"
# PROMETHEUS_MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../prometheus" && pwd)"
# GRAFANA_MANIFESTS_DIR="$(cd "$SCRIPT_DIR/../grafana" && pwd)"
# DASHBOARDS_DIR="$(cd "$SCRIPT_DIR/../dashboards" && pwd)"

if [[ -f "$PROJECT_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/.env"
  set +a
fi

export NAMESPACE="${NAMESPACE_OBSERVABILITY:-observability}"
export MLFLOW_IMAGE="${MLFLOW_IMAGE:-ghcr.io/mlflow/mlflow:v3.10.1}"
export MLFLOW_STORAGE_SIZE="${MLFLOW_STORAGE_SIZE:-10Gi}"
export OBSERVABILITY_READY_TIMEOUT="${OBSERVABILITY_READY_TIMEOUT:-300s}"
export MLFLOW_ENDPOINT="http://mlflow-tracking.${NAMESPACE}.svc.cluster.local:5000"

# Disabled — OTEL Collector is not deployed.
# export OTEL_COLLECTOR_IMAGE="${OTEL_COLLECTOR_IMAGE:-ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.120.0}"
# export OTEL_COLLECTOR_ENDPOINT="http://otel-collector.${NAMESPACE}.svc.cluster.local"
