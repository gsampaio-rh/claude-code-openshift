# ADR-028: Bidirectional Slack Integration via slack-bridge

**Status:** Accepted
**Date:** 2026-04-16
**Deciders:** Platform Engineering

## Context

Users interact with the Claude Code agent via `oc exec` into the pod. This requires OpenShift CLI access and terminal familiarity. We need a more accessible interface for broader teams.

We evaluated three integration approaches:

**Option A — Slack listener in the agent container:**
- Background process in `entrypoint.sh`, subprocess `claude -p` directly
- Zero new infrastructure, simplest implementation
- Couples Slack lifecycle to agent pod

**Option B — Slack bridge as standalone Deployment:**
- Separate pod, own image, own ServiceAccount
- Uses Kubernetes exec API to invoke `claude -p` in the agent pod
- Modular, independent lifecycle, clean RBAC boundary

**Option C — Official Slack MCP plugin (`mcp.slack.com`):**
- Remote MCP server with OAuth browser flow
- Agent-initiated only (no user-to-agent path)
- Requires browser-based authentication — incompatible with headless agents

## Decision

**Option B for user-to-agent** (slack-bridge standalone Deployment) + **custom local MCP server for agent-to-user** (slack-notify via stdio).

## Rationale

1. **Modularity.** The slack-bridge has its own image, lifecycle, and scaling. Deploying or removing it has zero impact on the agent container. This follows the same decoupling principle as agents-observe (ADR-024).

2. **Socket Mode eliminates public ingress.** The bridge connects to Slack via an outbound WebSocket — no Route, no public URL, works behind firewalls and NAT. The only requirement is outbound HTTPS to `wss://wss-primary.slack.com`.

3. **K8s exec is the natural bridge.** The agent runs `claude -p` via CLI. The bridge does exactly what a human does with `oc exec`, just automated. No HTTP wrapper needed, no new protocol.

4. **Local MCP for agent-initiated messages.** The official Slack MCP requires browser OAuth (incompatible with headless). A local MCP server using the Bot Token via stdio gives the agent `slack_send_message` and `slack_reply_thread` tools with zero external dependencies.

5. **Hook notifications for fire-and-forget.** `send_slack.sh` posts to a configured channel on `Stop` and `PostToolUseFailure` — complementary to the MCP tools which require the agent to decide to use them.

## Architecture

```
User → Slack → Socket Mode → slack-bridge pod → k8s exec → claude -p → response → Slack
Agent → MCP tool (slack_send_message) → slack-notify.mjs → Slack API → channel/DM
Agent → hook (Stop/Error) → send_slack.sh → curl → Slack API → channel
```

## Session Mapping

Hybrid approach:
- **In a Slack thread:** first message creates a Claude Code session. Subsequent messages in the same thread use `--resume <session_id>`. Mapping stored in-memory (lost on pod restart).
- **Direct in channel (no thread):** each message is an independent `claude -p` invocation.

## RBAC

The slack-bridge ServiceAccount has a minimal Role:
- `pods/get`, `pods/list` — find the agent pod by label
- `pods/exec` — invoke `claude -p`
- Scoped to `agent-sandboxes` namespace only

## Trade-offs

- **In-memory session mapping** — thread-to-session mapping is lost on bridge pod restart (no persistent store). Acceptable for PoC; production would need Redis or a ConfigMap-backed store.
- **Exec latency** — each message incurs K8s exec overhead (~2-5s) plus model inference time. Not suitable for real-time chat, but adequate for async agent tasks.
- **Two Deployments** — slack-bridge adds operational surface (image builds, RBAC, NetworkPolicy egress for Slack). Justified by clean separation of concerns.
- **Bot Token scope** — the same Bot Token is shared between the bridge (posting responses) and the agent MCP (agent-initiated messages). A compromised agent pod could post to any channel the bot has access to.
- **No Option A simplicity** — embedding the listener in the agent container would eliminate the exec hop and RBAC, but couples Slack lifecycle to the agent and requires rebuilding the agent image for any Slack change.

## Consequences

- New Deployment (`slack-bridge`) in `agent-sandboxes` namespace
- Requires Slack App setup (one-time manual): Bot Token + App Token in OpenShift Secret
- `claude-slack-tokens` Secret referenced by both slack-bridge and claude-code-standalone (optional for agent)
- Agent has `slack_send_message` and `slack_reply_thread` MCP tools when `SLACK_BOT_TOKEN` is set
- Automatic Slack notifications on session end and tool failures via hooks
- Egress NetworkPolicy may need updating to allow outbound to `slack.com` (443)
