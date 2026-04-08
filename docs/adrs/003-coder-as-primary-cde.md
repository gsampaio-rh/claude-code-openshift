# ADR-003: Coder as Primary CDE (Dev Spaces as Future Addition)

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

Developers need a Cloud Development Environment (CDE) to access Claude Code in isolated workspaces. Options:

1. **OpenShift Dev Spaces** (Eclipse Che) — included in OpenShift subscription
2. **Coder** — open-source, infrastructure-agnostic CDE
3. **No CDE** — developers SSH directly into pods

## Decision

Use **Coder** as the primary CDE. Add **Dev Spaces** as an alternative post-PoC (Phase 9).

## Rationale

- **Terraform-based provisioning**: Coder uses Terraform templates for workspace definition, giving full control over pod spec (including `runtimeClassName: kata`, labels, env vars, sidecars). Dev Spaces uses Devfiles which are more constrained.
- **Anthropic uses Coder**: the Coder+Anthropic blog shows this is the pattern Anthropic engineers use for multi-agent Claude Code. Proven at scale.
- **Multi-IDE support**: Coder supports VS Code (desktop and web), JetBrains (desktop and web), and SSH. Dev Spaces supports VS Code Web and JetBrains (IntelliJ Ultimate only).
- **Stronger workspace isolation model**: Coder's architecture separates the control plane from workspaces cleanly, making it easier to put workspaces in Kata VMs.
- **OpenShift compatible**: Coder has official OpenShift documentation and Helm chart with SCC configurations.

## Trade-offs

- **Not included in OpenShift subscription**: Coder is AGPL (free) for the core but requires separate installation and maintenance. Dev Spaces is "free" with OpenShift.
- **Requires PostgreSQL**: Coder needs a PostgreSQL instance. Dev Spaces uses its own storage.
- **SCC complexity**: Coder on OpenShift requires careful SecurityContext configuration (`restricted-v2`, custom UID/GID). Dev Spaces is pre-configured for OpenShift.
- **Two CDEs eventually**: supporting both Coder and Dev Spaces adds operational overhead.

## Consequences

- PostgreSQL must be deployed in the `coder` namespace
- Coder Helm chart must be configured with OpenShift-compatible SecurityContext
- Terraform workspace template must be created with Claude Code, Kata runtime, and all env vars
- OIDC authentication must be configured against OpenShift OAuth
- Route with TLS must be created for external access
- Dev Spaces Operator installation deferred to Phase 9
