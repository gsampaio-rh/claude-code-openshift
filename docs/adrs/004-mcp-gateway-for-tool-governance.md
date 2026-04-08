# ADR-004: MCP Gateway for Tool Governance

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

Claude Code accesses external tools via MCP (Model Context Protocol) — GitHub, filesystem, Jira, etc. Without governance, any agent can call any tool with any credentials. Prompt injection attacks can trick agents into calling unauthorized tools.

Options:

1. **Manual MCP config per workspace** — each workspace gets its own `.claude/settings.json` with MCP server configs
2. **MCP Gateway** — centralized Envoy-based gateway that aggregates all MCP servers behind a single endpoint with identity-based access control
3. **No MCP** — disable tool access entirely

## Decision

Use the **MCP Gateway** (Envoy-based, from the Kuadrant project) with **Kuadrant AuthPolicy + Authorino** for identity-based tool filtering.

## Rationale

- **Security by identity, not by prompt**: the gateway validates JWT token claims to determine which tools an agent can access. Prompt injection that tries to call unauthorized tools is blocked at the infrastructure layer — the gateway ignores prompt content entirely.
- **Single endpoint**: agents set one `MCP_URL` environment variable. Tool discovery and routing are handled by the gateway. No per-workspace MCP configuration needed.
- **Token exchange (RFC 8693)**: broad access tokens are exchanged for narrowly-scoped tokens per backend MCP server. A GitHub token used for repo access cannot be reused for Jira.
- **Credential isolation**: MCP server credentials stay in the gateway (Vault/Secrets), never in the agent pod.
- **Part of Red Hat AI BYOA strategy**: the MCP Gateway is built by the OpenShift networking team and is a core component of the AgentOps architecture.

## Trade-offs

- **Tech Preview**: MCP Gateway is not GA yet. Breaking changes possible.
- **Additional infrastructure**: requires Istio/Envoy Gateway, Gateway API CRDs, Kuadrant, Authorino.
- **Latency**: every tool call goes through the gateway (additional network hop). Expected <10ms overhead.
- **Complexity**: OPA policies for tool filtering require careful design and testing.

## Consequences

- Gateway API CRDs + Istio (via Sail Operator) must be installed
- MCP Gateway deployed via Helm in `mcp-gateway` namespace
- Kuadrant AuthPolicy + Authorino configured for JWT validation
- OPA rules defined per role (dev, admin, etc.)
- Claude Code configured with `MCP_URL` pointing to gateway
- MCP server credentials stored in K8s Secrets or Vault
