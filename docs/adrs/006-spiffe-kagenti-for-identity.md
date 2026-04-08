# ADR-006: SPIFFE/Kagenti for Agent Identity

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

Agents need identity to authenticate with the MCP Gateway, to be tracked in observability, and to be audited. Current common practice is API keys in environment variables or K8s Secrets.

Options:

1. **Static API keys in Secrets** — simple, widely used, no rotation
2. **K8s ServiceAccount tokens** — bound to pod lifecycle, auto-rotated
3. **SPIFFE/SPIRE via Kagenti** — cryptographic workload identity with automatic sidecar injection

## Decision

Use **SPIFFE/SPIRE** for agent identity, managed by the **Kagenti Operator** which auto-discovers agents and injects identity sidecars.

## Rationale

- **No hardcoded keys**: SPIFFE provides X.509 SVIDs (Secure Verifiable Identity Documents) that are automatically provisioned and rotated. No API keys in env vars or Secrets.
- **Zero-trust**: each agent gets a unique cryptographic identity in the form `spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`. Identity is verified, not assumed.
- **Automatic injection**: Kagenti Operator watches for pods with label `kagenti.io/type: agent` and automatically injects two sidecars:
  - `spiffe-helper`: fetches and rotates SVIDs
  - `kagenti-client-registration`: registers agent as OAuth2 client in Keycloak
- **Token exchange**: SVIDs are exchanged for OAuth2 tokens with claims (role, namespace, agent-id) used by the MCP Gateway for tool authorization.
- **Lifecycle management**: Kagenti auto-creates AgentCard CRDs for discovered agents, providing a catalog of all running agents.
- **Part of Red Hat AI roadmap**: Kagenti is planned as part of OpenShift AI for agent lifecycle management.

## Trade-offs

- **Alpha maturity**: Kagenti Operator is v0.2.0-alpha. Breaking changes expected.
- **Complexity**: requires SPIRE server, Keycloak (or existing IdP), and Kagenti Operator. Significantly more infrastructure than static API keys.
- **OpenShift SCC issues**: Kagenti had a known bug with hardcoded UID/GID conflicting with OpenShift SCCs (fixed in recent versions, but may resurface).
- **Debugging difficulty**: when identity injection fails, debugging sidecar injection and SPIRE attestation is harder than checking an env var.

## Consequences

- Kagenti Operator deployed in `agentops` namespace
- SPIRE Server deployed in `agentops` namespace
- Keycloak (or existing IdP) configured for OAuth2 token exchange
- All agent pods must have label `kagenti.io/type: agent`
- Coder Terraform template must include the label
- MCP Gateway AuthPolicy must be configured to validate tokens issued by Keycloak
- AgentCard CRDs provide a live catalog of running agents
