# ADR-015: Structured Logging via Entrypoint and claude-logged Wrapper

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

The Claude Code standalone pod originally used `CMD ["sleep", "infinity"]` as its main process. Claude Code was invoked ad-hoc via `oc exec`, meaning all output went to the exec caller — not to the container's stdout. As a result, `oc logs` and the OpenShift web console showed nothing.

For observability in production (log aggregation via EFK/Loki/CloudWatch, incident investigation, usage auditing), we need Claude Code invocations to appear in the container's standard log stream.

## Decision

Replace `sleep infinity` with a custom entrypoint that:

1. **Startup banner** — Logs version, model, endpoint, and usage instructions to stdout on container start.
2. **Log tail** — Background `tail -F` on a fixed NDJSON log file (`/tmp/claude-logs/claude.jsonl`) pipes log entries to container stdout.
3. **`claude-logged` wrapper** — Runs `claude -p --verbose --output-format stream-json` and tees output to both the caller and the log file.

Three invocation modes:

| Command | Output format | Appears in `oc logs` |
|---|---|---|
| `claude` | Interactive TUI | No (oc exec session) |
| `claude -p "..."` | Plain text to caller | No |
| `claude-logged "..."` | NDJSON to caller + log file | Yes |

## NDJSON Format

Each `claude-logged` invocation produces 3+ lines:

```json
{"type":"system","subtype":"init","session_id":"...","model":"qwen25-14b","claude_code_version":"2.1.96","tools":[...]}
{"type":"assistant","message":{"content":[{"type":"text","text":"..."}],"usage":{"input_tokens":22310,"output_tokens":2}}}
{"type":"result","subtype":"success","duration_ms":416,"duration_api_ms":246,"num_turns":1,"result":"8","total_cost_usd":0.11}
```

Fields useful for observability: `session_id`, `duration_ms`, `input_tokens`, `output_tokens`, `model`, `tools`, `result`.

## Files

- `infra/claude-code/entrypoint.sh` — Container entrypoint
- `infra/claude-code/claude-logged` — Wrapper script (installed to `/usr/local/bin/`)
- `infra/claude-code/Dockerfile` — Updated CMD to use entrypoint

## Consequences

- `oc logs` and OpenShift console now show startup info and all `claude-logged` invocations
- Plain `claude -p` still works but doesn't log to container stdout (use for quick tests)
- NDJSON format is parseable by any log aggregation stack without custom parsers
- Phase 7 (OTEL) will add native telemetry; this logging is complementary, not a replacement
- Log file grows unbounded in `/tmp/claude-logs/` — acceptable for PoC, production needs rotation
