#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0; FAIL=0; WARN=0; INFO=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
info() { echo "  [INFO] $1"; INFO=$((INFO + 1)); }

echo "============================================================"
echo " AgentOps | Pre-flight Check"
echo "============================================================"
echo ""

# ── 1. Authentication ────────────────────────────────────────

echo "1. Authentication"

if oc whoami &>/dev/null; then
  USER=$(oc whoami)
  pass "Logged in as: $USER"
else
  fail "Not logged in to OpenShift — run 'oc login' first"
  echo ""
  exit 1
fi

SERVER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
info "API server: $SERVER"

if oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  pass "Cluster admin access confirmed"
else
  warn "No cluster-admin role — some operations may fail"
fi

echo ""

# ── 2. OpenShift Version ─────────────────────────────────────

echo "2. OpenShift Version"

OCP_VERSION=$(oc version -o json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('openshiftVersion','unknown'))" 2>/dev/null \
  || echo "unknown")

info "OpenShift version: $OCP_VERSION"

OCP_MAJOR=$(echo "$OCP_VERSION" | cut -d. -f1)
OCP_MINOR=$(echo "$OCP_VERSION" | cut -d. -f2)
if [[ "$OCP_MAJOR" -ge 4 && "$OCP_MINOR" -ge 16 ]]; then
  pass "Version >= 4.16 (required for Kata, KServe, RHOAI)"
else
  warn "Version $OCP_VERSION may be too old (recommended: 4.16+)"
fi

K8S_VERSION=$(oc version -o json 2>/dev/null \
  | python3 -c "import sys,json; sv=json.load(sys.stdin).get('serverVersion',{}); print(sv.get('major','?')+'.'+sv.get('minor','?'))" 2>/dev/null \
  || echo "unknown")
info "Kubernetes version: $K8S_VERSION"

echo ""

# ── 3. Node Resources ────────────────────────────────────────

echo "3. Node Resources"

NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "Total nodes: $NODE_COUNT"

while IFS= read -r line; do
  NODE_NAME=$(echo "$line" | awk '{print $1}')
  NODE_CPU=$(echo "$line" | awk '{print $2}')
  NODE_MEM=$(echo "$line" | awk '{print $3}')
  NODE_GPU=$(echo "$line" | awk '{print $4}')
  GPU_DISPLAY="${NODE_GPU:-0}"

  info "Node: $NODE_NAME | CPU: $NODE_CPU | Memory: $NODE_MEM | GPU: ${GPU_DISPLAY}x"
done < <(oc get nodes -o custom-columns=\
'NAME:.metadata.name,'\
'CPU:.status.allocatable.cpu,'\
'MEMORY:.status.allocatable.memory,'\
'GPU:.status.allocatable.nvidia\.com/gpu' \
  --no-headers 2>/dev/null)

GPU_NODES=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '$1 > 0' | wc -l | tr -d ' ')

TOTAL_GPUS=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null \
  | awk '{s+=$1} END {print s+0}')

if [[ "$GPU_NODES" -ge 1 ]]; then
  pass "GPU nodes: $GPU_NODES (total GPUs: $TOTAL_GPUS)"
else
  fail "No GPU nodes detected — vLLM requires at least 1 NVIDIA GPU"
fi

GPU_PRODUCT=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.labels.nvidia\.com/gpu\.product}{"\n"}{end}' 2>/dev/null \
  | sort -u | grep -v '^$' | head -1 || echo "")
if [[ -n "$GPU_PRODUCT" ]]; then
  info "GPU model: $GPU_PRODUCT"
fi

echo ""

# ── 4. Installed Operators ────────────────────────────────────

echo "4. Installed Operators"

check_operator() {
  local name="$1"
  local pattern="$2"
  local required="${3:-recommended}"

  CSV_LINE=$(oc get csv -A --no-headers 2>/dev/null | grep -i "$pattern" | head -1 || echo "")
  if [[ -n "$CSV_LINE" ]]; then
    CSV_STATUS=$(echo "$CSV_LINE" | awk '{print $NF}')
    CSV_NAME=$(echo "$CSV_LINE" | awk '{print $2}')
    if [[ "$CSV_STATUS" == "Succeeded" ]]; then
      pass "$name: $CSV_NAME ($CSV_STATUS)"
    else
      warn "$name: $CSV_NAME (status: $CSV_STATUS)"
    fi
  else
    if [[ "$required" == "required" ]]; then
      fail "$name: not installed"
    else
      warn "$name: not installed"
    fi
  fi
}

check_operator "NVIDIA GPU Operator"        "gpu-operator"            "required"
check_operator "Node Feature Discovery"     "nfd\|node-feature"       "required"
check_operator "Red Hat OpenShift AI"       "rhods\|opendatahub"      "recommended"
check_operator "OpenShift Serverless"       "serverless"              "recommended"
check_operator "OpenShift Pipelines"        "pipelines\|tekton"       "recommended"
check_operator "cert-manager"               "cert-manager"            "recommended"
check_operator "Sandboxed Containers"       "sandboxed-containers"    "recommended"

echo ""

# ── 5. Existing Workloads ────────────────────────────────────

echo "5. Existing Workloads (potential conflicts)"

IS_COUNT=$(oc get inferenceservice -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$IS_COUNT" -gt 0 ]]; then
  warn "Found $IS_COUNT existing InferenceService(s):"
  oc get inferenceservice -A --no-headers 2>/dev/null | while read -r line; do
    NS=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | awk '{print $2}')
    READY=$(echo "$line" | awk '{print $4}')
    info "  $NS/$NAME (ready: $READY)"
  done
else
  pass "No existing InferenceServices"
fi

GPU_PODS=$(oc get pods -A -o json 2>/dev/null \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
gpu_pods = []
for pod in data.get('items', []):
    ns = pod['metadata']['namespace']
    name = pod['metadata']['name']
    phase = pod.get('status', {}).get('phase', '')
    if phase not in ('Running', 'Pending'):
        continue
    for c in pod.get('spec', {}).get('containers', []):
        limits = c.get('resources', {}).get('limits', {})
        gpu = limits.get('nvidia.com/gpu', '0')
        if int(gpu) > 0:
            gpu_pods.append(f'{ns}/{name} ({gpu} GPU)')
for p in gpu_pods:
    print(p)
" 2>/dev/null || echo "")

if [[ -n "$GPU_PODS" ]]; then
  warn "Pods currently consuming GPUs:"
  echo "$GPU_PODS" | while read -r p; do info "  $p"; done
  echo ""
  echo "  These pods must be stopped to free GPUs for vLLM."
else
  pass "No pods currently consuming GPUs"
fi

echo ""

# ── 6. Registry & Pull Secrets ────────────────────────────────

echo "6. Registry & Pull Secrets"

PULL_SECRET=$(oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if echo "$PULL_SECRET" | grep -q "registry.redhat.io"; then
  pass "registry.redhat.io pull secret configured"
else
  warn "registry.redhat.io pull secret not found — RHAIIS images won't pull"
fi

if echo "$PULL_SECRET" | grep -q "quay.io"; then
  pass "quay.io pull secret configured"
else
  info "quay.io pull secret not found (optional)"
fi

echo ""

# ── 7. DataScienceCluster ────────────────────────────────────

echo "7. OpenShift AI Configuration"

DSC_KSERVE=$(oc get datasciencecluster -A -o jsonpath='{.items[0].spec.components.kserve.managementState}' 2>/dev/null || echo "")
DSC_MM=$(oc get datasciencecluster -A -o jsonpath='{.items[0].spec.components.modelmeshserving.managementState}' 2>/dev/null || echo "")

if [[ -n "$DSC_KSERVE" ]]; then
  info "KServe: $DSC_KSERVE"
else
  info "KServe: not configured (DataScienceCluster not found)"
fi

if [[ -n "$DSC_MM" ]]; then
  info "ModelMesh: $DSC_MM"
fi

KSERVE_CRDS=$(oc get crd inferenceservices.serving.kserve.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$KSERVE_CRDS" -ge 1 ]]; then
  pass "KServe CRDs installed"
else
  info "KServe CRDs not found (not needed for plain Deployment approach — ADR-012)"
fi

echo ""

# ── 8. Network & DNS ─────────────────────────────────────────

echo "8. Network & DNS"

if oc get dns cluster -o jsonpath='{.spec.baseDomain}' &>/dev/null; then
  BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null)
  info "Base domain: $BASE_DOMAIN"
  pass "Cluster DNS configured"
else
  warn "Could not read cluster DNS config"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────

echo "============================================================"
echo " Results: $PASS passed, $FAIL failed, $WARN warnings, $INFO info"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "  Fix the FAIL items before proceeding."
  exit 1
fi

echo ""
echo "Pre-flight check complete. Proceed with cluster setup:"
echo "  ./01-setup-cluster.sh"
