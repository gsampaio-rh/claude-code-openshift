#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0; WARN=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

echo "============================================================"
echo " GPU | Infrastructure Validation"
echo "============================================================"
echo ""

# ── 1. GPU Nodes ─────────────────────────────────────────────

echo "1. GPU Nodes"

GPU_DATA=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\t"}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' 2>/dev/null \
  | awk '$2 > 0')

GPU_COUNT=$(echo "$GPU_DATA" | grep -c . 2>/dev/null || echo "0")

if [[ "$GPU_COUNT" -ge 1 ]]; then
  pass "Found $GPU_COUNT GPU node(s)"
  echo "$GPU_DATA" | while IFS=$'\t' read -r node gpus product; do
    echo "    $node — ${gpus}x ${product:-unknown}"
  done
else
  fail "No GPU nodes found"
  echo ""
  echo "============================================================"
  echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
  echo "============================================================"
  exit 1
fi
echo ""

# ── 2. GPU Operator ──────────────────────────────────────────

echo "2. GPU Operator"

GPU_CSV=$(oc get csv -n nvidia-gpu-operator -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | grep -i gpu | head -1 || echo "")

if [[ -n "$GPU_CSV" ]]; then
  CSV_NAME=$(echo "$GPU_CSV" | awk '{print $1}')
  CSV_PHASE=$(echo "$GPU_CSV" | awk '{print $2}')
  if [[ "$CSV_PHASE" == "Succeeded" ]]; then
    pass "GPU Operator: $CSV_NAME ($CSV_PHASE)"
  else
    warn "GPU Operator: $CSV_NAME ($CSV_PHASE)"
  fi
else
  warn "GPU Operator CSV not found in nvidia-gpu-operator namespace"
fi

NFD_CSV=$(oc get csv -n openshift-nfd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | grep -i "node-feature" | head -1 || echo "")

if [[ -n "$NFD_CSV" ]]; then
  pass "NFD Operator: $(echo "$NFD_CSV" | awk '{print $1, $2}')"
else
  warn "NFD Operator not found"
fi
echo ""

# ── 3. Driver & Runtime ─────────────────────────────────────

echo "3. NVIDIA Driver & Runtime"

GPU_NODE=$(echo "$GPU_DATA" | head -1 | awk '{print $1}')
if [[ -n "$GPU_NODE" ]]; then
  DRIVER_VER=$(oc get node "$GPU_NODE" -o jsonpath='{.metadata.labels.nvidia\.com/cuda\.driver\.major}' 2>/dev/null || echo "")
  CUDA_VER=$(oc get node "$GPU_NODE" -o jsonpath='{.metadata.labels.nvidia\.com/cuda\.runtime\.major}' 2>/dev/null || echo "")

  if [[ -n "$DRIVER_VER" ]]; then
    pass "NVIDIA driver major version: $DRIVER_VER"
  else
    warn "Could not detect NVIDIA driver version from node labels"
  fi

  if [[ -n "$CUDA_VER" ]]; then
    pass "CUDA runtime major version: $CUDA_VER"
  else
    warn "Could not detect CUDA version from node labels"
  fi

  GPU_PRODUCT=$(oc get node "$GPU_NODE" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}' 2>/dev/null || echo "unknown")
  GPU_MEMORY=$(oc get node "$GPU_NODE" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null || echo "unknown")
  pass "GPU: $GPU_PRODUCT (${GPU_MEMORY}MB VRAM)"
fi
echo ""

# ── 4. nodeSelector Match ───────────────────────────────────

echo "4. Deployment nodeSelector Match"

DEPLOY_FILE="$SCRIPT_DIR/../manifests/deployment.yaml"
if [[ -f "$DEPLOY_FILE" ]]; then
  SELECTOR_PRODUCT=$(grep "nvidia.com/gpu.product:" "$DEPLOY_FILE" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "")
  if [[ -n "$SELECTOR_PRODUCT" ]]; then
    MATCHING_NODES=$(echo "$GPU_DATA" | grep -c "$SELECTOR_PRODUCT" 2>/dev/null || echo "0")
    if [[ "$MATCHING_NODES" -ge 1 ]]; then
      pass "nodeSelector '$SELECTOR_PRODUCT' matches $MATCHING_NODES node(s)"
    else
      fail "nodeSelector '$SELECTOR_PRODUCT' matches 0 nodes — deployment will be unschedulable"
      echo "    Available GPU products:"
      echo "$GPU_DATA" | awk '{print "      " $3}' | sort -u
    fi
  else
    warn "No nvidia.com/gpu.product nodeSelector in deployment.yaml"
  fi
else
  warn "deployment.yaml not found at $DEPLOY_FILE"
fi
echo ""

# ── 5. Taints & Tolerations ────────────────────────────────

echo "5. Taints & Tolerations"

if [[ -n "$GPU_NODE" ]]; then
  TAINT=$(oc get node "$GPU_NODE" -o jsonpath='{.spec.taints}' 2>/dev/null || echo "[]")
  if echo "$TAINT" | grep -q "nvidia.com/gpu"; then
    pass "GPU node has nvidia.com/gpu taint"

    if [[ -f "$DEPLOY_FILE" ]] && grep -q "nvidia.com/gpu" "$DEPLOY_FILE"; then
      pass "Deployment has matching toleration"
    else
      warn "Deployment may be missing toleration for nvidia.com/gpu taint"
    fi
  else
    warn "GPU node has no nvidia.com/gpu taint (non-GPU pods may schedule on it)"
  fi
fi
echo ""

# ── 6. VRAM Capacity ───────────────────────────────────────

echo "6. VRAM Capacity Check"

if [[ -n "${GPU_MEMORY:-}" && "$GPU_MEMORY" != "unknown" ]]; then
  GPU_MEMORY_GB=$((GPU_MEMORY / 1024))
  pass "GPU VRAM: ${GPU_MEMORY_GB}GB (${GPU_MEMORY}MB)"

  if [[ "$GPU_MEMORY_GB" -ge 40 ]]; then
    pass "Tier: Comfortable (full 32K context, CUDA graphs, 16K output tokens)"
  elif [[ "$GPU_MEMORY_GB" -ge 20 ]]; then
    warn "Tier: Minimum (limited context ~24K, enforce-eager, 2K output tokens)"
  else
    fail "Tier: Insufficient (< 20GB — model may not fit)"
  fi
else
  warn "Could not determine GPU VRAM from node labels"
fi
echo ""

# ── 7. MachineSet (cloud) ──────────────────────────────────

echo "7. MachineSets (cloud environments)"

GPU_MS=$(oc get machinesets -n openshift-machine-api -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.spec.template.spec.providerSpec.value.instanceType}{"\n"}{end}' 2>/dev/null \
  | grep -E "g[5-9]|p[4-5]|a2-" || echo "")

if [[ -n "$GPU_MS" ]]; then
  pass "GPU MachineSet(s) found:"
  echo "$GPU_MS" | while IFS=$'\t' read -r name replicas itype; do
    echo "    $name — replicas: $replicas — instance: $itype"
  done
else
  warn "No GPU MachineSets found (may be bare metal or manually provisioned)"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "============================================================"

[[ "$FAIL" -gt 0 ]] && exit 1
echo ""
echo "GPU infrastructure is ready for vLLM deployment."
