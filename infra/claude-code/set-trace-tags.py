#!/usr/bin/env python3
"""Claude Code Stop hook that enriches MLflow traces with Kubernetes metadata.

Claude Code hooks receive JSON on stdin with session_id and transcript_path.
This hook runs AFTER the MLflow stop-hook (which creates the trace), then
polls the MLflow API until the trace for this session appears, and stamps it
with operational context from Downward API / ConfigMap env vars.

Installed as a Claude Code "Stop" hook handler by entrypoint.sh.
Ref: https://code.claude.com/docs/en/hooks
"""
import json
import os
import sys
import time
import urllib.request

hook_input = {}
try:
    raw = sys.stdin.read()
    if raw.strip():
        hook_input = json.loads(raw)
except Exception:
    pass

tracking_uri = os.environ.get("MLFLOW_TRACKING_URI", "")
experiment_name = os.environ.get("MLFLOW_EXPERIMENT_NAME", "claude-code-agents")
session_id = hook_input.get("session_id", "")
if not tracking_uri or not session_id:
    sys.exit(0)

tags = {
    "agentops.pod_name": os.environ.get("POD_NAME", ""),
    "agentops.node_name": os.environ.get("NODE_NAME", ""),
    "agentops.namespace": os.environ.get("POD_NAMESPACE", ""),
    "agentops.runtime_class": os.environ.get("AGENTOPS_RUNTIME_CLASS", ""),
    "agentops.model": os.environ.get("AGENTOPS_MODEL", ""),
    "agentops.cluster": os.environ.get("AGENTOPS_CLUSTER", ""),
    "agentops.gpu": os.environ.get("AGENTOPS_GPU", ""),
}
tags = {k: v for k, v in tags.items() if v}
if not tags:
    sys.exit(0)


def find_trace_by_session(exp_id, sid, max_attempts=10, interval=2):
    """Poll MLflow for a trace matching this session_id."""
    for _ in range(max_attempts):
        url = f"{tracking_uri}/api/2.0/mlflow/traces?experiment_ids={exp_id}&max_results=5"
        resp = urllib.request.urlopen(urllib.request.Request(url), timeout=5)
        for trace in json.loads(resp.read()).get("traces", []):
            metadata = {m["key"]: m["value"] for m in trace.get("request_metadata", [])}
            if metadata.get("mlflow.trace.session") == sid:
                return trace["request_id"]
        time.sleep(interval)
    return None


try:
    exp_url = f"{tracking_uri}/api/2.0/mlflow/experiments/get-by-name?experiment_name={experiment_name}"
    resp = urllib.request.urlopen(urllib.request.Request(exp_url), timeout=5)
    exp_id = json.loads(resp.read())["experiment"]["experiment_id"]

    request_id = find_trace_by_session(exp_id, session_id)
    if not request_id:
        sys.exit(0)

    for key, value in tags.items():
        req = urllib.request.Request(
            f"{tracking_uri}/api/2.0/mlflow/traces/{request_id}/tags",
            data=json.dumps({"key": key, "value": value}).encode(),
            headers={"Content-Type": "application/json"},
            method="PATCH",
        )
        urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
