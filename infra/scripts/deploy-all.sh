#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<EOF
AgentOps Platform — Full Deployment Orchestrator

Usage: $0 [OPTIONS]

Options:
  --skip-cluster    Skip cluster setup (namespaces, RBAC, quotas, operators)
  --skip-vllm       Skip vLLM deployment
  --skip-agent      Skip Claude Code agent build+deploy
  --skip-guardrails Skip Guardrails (TrustyAI) deployment
  --skip-kata       Skip Kata installation+validation
  --skip-verify     Skip verification steps
  --dry-run         Print what would be executed without running
  -h, --help        Show this help

Steps executed (in order):
  1. Cluster pre-flight check
  2. Cluster setup (namespaces, RBAC, quotas, network policies)
  3. Operator installation
  4. Kata Containers install + validation
  5. vLLM namespace setup + GPU validation
  6. vLLM model deployment
  7. vLLM validation
  8. Claude Code agent image build
  9. Claude Code agent deployment
  10. Claude Code verification
  11. Guardrails prerequisite check
  12. Guardrails deployment
  13. Guardrails verification
  14. End-to-end test

EOF
  exit 0
}

SKIP_CLUSTER=false
SKIP_VLLM=false
SKIP_AGENT=false
SKIP_GUARDRAILS=false
SKIP_KATA=false
SKIP_VERIFY=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --skip-cluster) SKIP_CLUSTER=true ;;
    --skip-vllm) SKIP_VLLM=true ;;
    --skip-agent) SKIP_AGENT=true ;;
    --skip-guardrails) SKIP_GUARDRAILS=true ;;
    --skip-kata) SKIP_KATA=true ;;
    --skip-verify) SKIP_VERIFY=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $arg"; usage ;;
  esac
done

step=0
run_step() {
  step=$((step + 1))
  local desc="$1"; shift
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  Step $step: $desc"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo ""
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY-RUN] Would execute: $*"
  else
    "$@"
  fi
}

skip_step() {
  step=$((step + 1))
  echo ""
  echo "── Step $step: $1 [SKIPPED] ──"
}

echo "============================================================"
echo " AgentOps Platform — Full Deployment"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
echo "User:    $(oc whoami)"

# ── Cluster ──────────────────────────────────────────────────

if [[ "$SKIP_CLUSTER" == "false" ]]; then
  run_step "Cluster pre-flight check" \
    bash "$INFRA_DIR/cluster/scripts/00-preflight-check.sh"

  run_step "Cluster setup (namespaces, RBAC, quotas)" \
    bash "$INFRA_DIR/cluster/scripts/01-setup-cluster.sh"

  run_step "Operator installation" \
    bash "$INFRA_DIR/cluster/scripts/02-install-operators.sh"
else
  skip_step "Cluster pre-flight check"
  skip_step "Cluster setup"
  skip_step "Operator installation"
fi

# ── Kata ─────────────────────────────────────────────────────

if [[ "$SKIP_KATA" == "false" ]]; then
  run_step "Kata Containers install" \
    bash "$INFRA_DIR/cluster/scripts/03-install-kata.sh"

  if [[ "$SKIP_VERIFY" == "false" ]]; then
    run_step "Kata validation" \
      bash "$INFRA_DIR/cluster/scripts/04-validate-kata.sh"
  else
    skip_step "Kata validation"
  fi
else
  skip_step "Kata install"
  skip_step "Kata validation"
fi

# ── vLLM ─────────────────────────────────────────────────────

if [[ "$SKIP_VLLM" == "false" ]]; then
  run_step "vLLM namespace setup + GPU check" \
    bash "$INFRA_DIR/vllm/scripts/00-setup-namespace.sh"

  run_step "GPU infrastructure validation" \
    bash "$INFRA_DIR/vllm/scripts/03-validate-gpu.sh"

  run_step "vLLM model deployment" \
    bash "$INFRA_DIR/vllm/scripts/01-deploy-model.sh"

  if [[ "$SKIP_VERIFY" == "false" ]]; then
    run_step "vLLM validation" \
      bash "$INFRA_DIR/vllm/scripts/02-validate-model.sh"
  else
    skip_step "vLLM validation"
  fi
else
  skip_step "vLLM namespace setup"
  skip_step "GPU validation"
  skip_step "vLLM deployment"
  skip_step "vLLM validation"
fi

# ── Claude Code ──────────────────────────────────────────────

if [[ "$SKIP_AGENT" == "false" ]]; then
  run_step "Claude Code setup check" \
    bash "$INFRA_DIR/claude-code/scripts/00-setup.sh"

  run_step "Claude Code image build" \
    bash "$INFRA_DIR/claude-code/scripts/build-image.sh"

  run_step "Claude Code standalone deploy" \
    bash "$INFRA_DIR/claude-code/scripts/01-deploy-standalone.sh"

  if [[ "$SKIP_VERIFY" == "false" ]]; then
    run_step "Claude Code verification" \
      bash "$INFRA_DIR/claude-code/scripts/99-verify.sh"
  else
    skip_step "Claude Code verification"
  fi
else
  skip_step "Claude Code setup"
  skip_step "Claude Code build"
  skip_step "Claude Code deploy"
  skip_step "Claude Code verification"
fi

# ── Guardrails ────────────────────────────────────────────────

if [[ "$SKIP_GUARDRAILS" == "false" ]]; then
  run_step "Guardrails prerequisite check" \
    bash "$INFRA_DIR/guardrails/scripts/00-check-prerequisites.sh"

  run_step "Guardrails deployment" \
    bash "$INFRA_DIR/guardrails/scripts/01-deploy-guardrails.sh"

  if [[ "$SKIP_VERIFY" == "false" ]]; then
    run_step "Guardrails verification" \
      bash "$INFRA_DIR/guardrails/scripts/99-verify.sh"
  else
    skip_step "Guardrails verification"
  fi
else
  skip_step "Guardrails prerequisite check"
  skip_step "Guardrails deployment"
  skip_step "Guardrails verification"
fi

# ── E2E ──────────────────────────────────────────────────────

if [[ "$SKIP_VERIFY" == "false" ]]; then
  run_step "End-to-end validation" \
    bash "$INFRA_DIR/scripts/e2e-test.sh"
else
  skip_step "E2E validation"
fi

echo ""
echo "============================================================"
echo " Deployment complete — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"
