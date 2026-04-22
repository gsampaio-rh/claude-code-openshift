#!/usr/bin/env bash
set -euo pipefail

#
# Creates a MachineSet from a template by resolving cluster-specific placeholders.
#
# Reads CLUSTER_ID, AMI_ID, CLUSTER_GUID, and CLUSTER_UUID from the live cluster
# (existing worker MachineSet + infrastructure object), then substitutes into the
# template YAML and applies it.
#
# Usage:
#   bash infra/cluster/scripts/create-machineset.sh gpu-l40s
#   bash infra/cluster/scripts/create-machineset.sh kata-baremetal
#   bash infra/cluster/scripts/create-machineset.sh gpu-l40s --dry-run
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINESETS_DIR="$(cd "$SCRIPT_DIR/../machinesets" && pwd)"

TEMPLATE_NAME="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ -z "$TEMPLATE_NAME" ]]; then
  echo "Usage: $0 <template-name> [--dry-run]"
  echo ""
  echo "Available templates:"
  ls "$MACHINESETS_DIR"/*.yaml 2>/dev/null | while read -r f; do
    basename "$f" .yaml
  done
  exit 1
fi

TEMPLATE_FILE="$MACHINESETS_DIR/${TEMPLATE_NAME}.yaml"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "ERROR: Template not found: $TEMPLATE_FILE"
  exit 1
fi

echo "Discovering cluster metadata..."

CLUSTER_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo "  CLUSTER_ID:   $CLUSTER_ID"

WORKER_MS=$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$WORKER_MS" ]]; then
  echo "ERROR: No existing MachineSets found to extract metadata from."
  exit 1
fi

AMI_ID=$(oc get machineset "$WORKER_MS" -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.ami.id}')
echo "  AMI_ID:       $AMI_ID"

CLUSTER_GUID=$(oc get machineset "$WORKER_MS" -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.tags}' \
  | python3 -c "import sys,json; tags=json.loads(sys.stdin.read()); print(next(t['value'] for t in tags if t['name']=='guid'))" 2>/dev/null \
  || echo "unknown")
echo "  CLUSTER_GUID: $CLUSTER_GUID"

CLUSTER_UUID=$(oc get machineset "$WORKER_MS" -n openshift-machine-api \
  -o jsonpath='{.spec.template.spec.providerSpec.value.tags}' \
  | python3 -c "import sys,json; tags=json.loads(sys.stdin.read()); print(next(t['value'] for t in tags if t['name']=='uuid'))" 2>/dev/null \
  || echo "unknown")
echo "  CLUSTER_UUID: $CLUSTER_UUID"

echo ""

export CLUSTER_ID AMI_ID CLUSTER_GUID CLUSTER_UUID
RENDERED=$(envsubst < "$TEMPLATE_FILE")

if [[ "$DRY_RUN" == "true" ]]; then
  echo "--- DRY RUN (would apply): ---"
  echo "$RENDERED"
else
  MS_NAME=$(echo "$RENDERED" | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['metadata']['name'])" 2>/dev/null || echo "$TEMPLATE_NAME")

  EXISTING=$(oc get machineset "$MS_NAME" -n openshift-machine-api --no-headers 2>/dev/null || echo "")
  if [[ -n "$EXISTING" ]]; then
    echo "MachineSet '$MS_NAME' already exists:"
    echo "  $EXISTING"
    echo ""
    echo "To recreate, delete it first: oc delete machineset $MS_NAME -n openshift-machine-api"
    exit 0
  fi

  echo "$RENDERED" | oc apply -f -
  echo ""
  echo "MachineSet created. Monitor with:"
  echo "  oc get machines -n openshift-machine-api -w"
fi
