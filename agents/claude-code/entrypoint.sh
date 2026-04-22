#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${CLAUDE_LOG_DIR:-/tmp/claude-logs}"
LOG_FILE="$LOG_DIR/claude.jsonl"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# ── Claude Code global config (rules, skills, CLAUDE.md) ────
RULES_SKILLS="/opt/app-root/rules-skills/.claude"
if [[ -d "$RULES_SKILLS" ]]; then
  mkdir -p "$HOME/.claude"
  cp -r "$RULES_SKILLS"/* "$HOME/.claude/" 2>/dev/null || true
fi

# ── Observability hooks setup (merge into settings.json) ────
HOOKS_SETTINGS="/opt/app-root/hooks/settings.json"
if [[ -f "$HOOKS_SETTINGS" ]]; then
  mkdir -p "$HOME/.claude"
  if [[ -f "$HOME/.claude/settings.json" ]]; then
    python3.12 -c "
import json, sys
with open('$HOME/.claude/settings.json') as f: base = json.load(f)
with open('$HOOKS_SETTINGS') as f: hooks = json.load(f)
base.update(hooks)
with open('$HOME/.claude/settings.json', 'w') as f: json.dump(base, f, indent=2)
"
  else
    cp "$HOOKS_SETTINGS" "$HOME/.claude/settings.json"
  fi
fi

# ── Slack MCP server setup (agent → Slack) ───────────────────
if [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
  mkdir -p "$HOME/.claude"
  python3.12 -c "
import json, os
mcp_path = os.path.join(os.environ['HOME'], '.claude', '.mcp.json')
mcp = {}
if os.path.exists(mcp_path):
    with open(mcp_path) as f: mcp = json.load(f)
mcp.setdefault('mcpServers', {})['slack-notify'] = {
    'command': 'node',
    'args': ['/opt/app-root/mcp/slack-notify.mjs']
}
with open(mcp_path, 'w') as f: json.dump(mcp, f, indent=2)
"
fi

# ── MLflow tracing setup ─────────────────────────────────────
MLFLOW_TRACING="disabled"
if [[ -n "${MLFLOW_TRACKING_URI:-}" ]] && command -v mlflow &>/dev/null; then
  MLFLOW_ARGS=(-u "$MLFLOW_TRACKING_URI")
  [[ -n "${MLFLOW_EXPERIMENT_NAME:-}" ]] && MLFLOW_ARGS+=(-n "$MLFLOW_EXPERIMENT_NAME")
  if mlflow autolog claude "${MLFLOW_ARGS[@]}" 2>/dev/null; then
    MLFLOW_TRACING="enabled → $MLFLOW_TRACKING_URI"

    # Per-trace metadata enrichment (set-trace-tags.py) is DISABLED.
    # Experiment-level tags are sufficient for the PoC (single agent).
    # Re-enable when multi-agent requires per-trace pod/node identification.
    # See ADR-020 for rationale and implementation details.
  else
    MLFLOW_TRACING="failed (check mlflow autolog claude --status)"
  fi
fi

echo "============================================================"
echo " Claude Code Agent — Standalone Pod"
echo "============================================================"
echo ""
echo "  Version:    $(claude --version 2>/dev/null || echo 'not found')"
echo "  Base URL:   ${ANTHROPIC_BASE_URL:-not set}"
echo "  Model:      ${ANTHROPIC_DEFAULT_SONNET_MODEL:-not set}"
echo "  Max Output: ${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-default}"
echo "  MLflow:     $MLFLOW_TRACING"
echo "  Rules:      $(test -d "$HOME/.claude/rules" && echo "enabled → $(ls "$HOME/.claude/rules/" | wc -l | tr -d ' ') rules" || echo 'disabled')"
echo "  Skills:     $(test -d "$HOME/.claude/skills" && echo "enabled → $(ls "$HOME/.claude/skills/" | wc -l | tr -d ' ') skills" || echo 'disabled')"
echo "  Hooks:      $(test -f "$HOME/.claude/settings.json" && echo 'enabled → agents-observe' || echo 'disabled')"
echo "  Slack MCP:  $(test -f "$HOME/.claude/.mcp.json" && echo 'enabled → slack-notify' || echo 'disabled')"
echo "  Log Dir:    $LOG_DIR"
echo "  Started:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "  Usage:"
echo "    oc exec -it <pod> -- claude              # interactive"
echo "    oc exec <pod> -- claude -p 'prompt'      # headless"
echo "    oc exec <pod> -- claude-logged 'prompt'  # headless + logs to oc logs"
echo ""
echo "  Logs stream below (from claude-logged invocations):"
echo "------------------------------------------------------------"

tail -F "$LOG_FILE" &
TAIL_PID=$!
trap "kill $TAIL_PID 2>/dev/null" EXIT

exec sleep infinity
