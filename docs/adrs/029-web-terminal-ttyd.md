# ADR-029: Web Terminal via ttyd for Interactive Agent Access

**Status:** Accepted
**Date:** 2026-04-22
**Deciders:** AgentOps team

## Context

The Claude Code agent running inside a Kata MicroVM on OpenShift has several access methods, each with trade-offs:

1. **`oc exec`** — requires CLI, OpenShift knowledge, and VPN
2. **Slack bridge** — one-shot `claude -p`, no streaming or tool approvals
3. **claude-devtools sidecar** — read-only session viewer

None provide a **real interactive Claude Code session** with streaming output, tool approval prompts, and session continuity — the way users experience it locally.

### Options Considered

1. **ttyd** — 6MB static binary (C + libwebsockets + xterm.js), basic auth, single command to start
2. **Wetty** — Node.js (~200MB image), requires SSH daemon in the agent container
3. **OpenShift Web Terminal Operator** — creates separate DevWorkspace pods outside the Kata sandbox
4. **Claude Remote Control** — requires claude.ai login + Pro/Max plan, incompatible with self-hosted models

## Decision

Embed **ttyd** directly in the `claude-code-agent` Dockerfile (Option B from the plan). The binary is started by `entrypoint.sh` on port 7681, exposed via an OpenShift Route with edge TLS.

## Rationale

- **Smallest footprint:** 6MB static binary vs 200MB+ Node.js for Wetty
- **No extra infrastructure:** runs inside the existing agent container, no SSH daemon
- **Inside the sandbox:** unlike the Web Terminal Operator which creates separate pods, ttyd runs inside the Kata MicroVM — same blast radius as `oc exec`
- **Avoids PID namespace complexity:** Option A (sidecar + `nsenter`) may not work reliably across Kata boundaries; Option B is simpler
- **Full interactive experience:** streaming, tool approvals, multi-turn conversations, all from a browser

## Trade-offs

- **Mixes concerns:** terminal server lives in the agent image (6MB overhead)
- **Single concurrent user:** ttyd defaults to one client per terminal; use `--max-clients N` to increase
- **Basic auth only:** ttyd supports `--credential user:password`; for stronger auth, front with OAuth Proxy
- **No session persistence:** if the pod restarts, the terminal session is lost (same as `oc exec`)

## Consequences

- `agents/claude-code/Dockerfile` installs ttyd from GitHub releases
- `agents/claude-code/entrypoint.sh` starts `ttyd -p 7681 --writable bash &` before `sleep infinity`
- `TTYD_CREDENTIAL` env var (from optional Secret `claude-web-terminal`) enables basic auth
- New Service + Route expose port 7681 via `https://claude-web-terminal-agent-sandboxes.apps.<cluster>/`
- Slack bridge and `oc exec` remain available for their respective use cases
