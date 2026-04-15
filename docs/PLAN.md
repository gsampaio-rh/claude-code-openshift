# Plan: AgentOps Platform

**Status:** Sprint 2 (in progress)
**Date:** 2026-04-14
**Related:** [PRD](PRD.md) | [Architecture](ARCHITECTURE.md) | [ADRs](adrs/) | [Changelog](CHANGELOG.md) | [Future Explorations](FUTURE_EXPLORATIONS.md)

---

## Overview

The AgentOps platform runs AI coding agents (Claude Code) on OpenShift with isolation, identity, governance, observability, and safety — without modifying the agent (BYOA principle). Five 1-week sprints cover PRD Phases 0–8, plus post-PoC exploration. Phase 9 (Dev Spaces) is post-PoC.

```
Sprint 1 ████████████████████ Infrastructure + Inference + Standalone Agent  ✅ DONE
Sprint 2 ████████████░░░░░░░░ Observability + Safety + CDE + UI/Multi-Agent ← CURRENT
Sprint 3 ░░░░░░░░░░░░░░░░░░░░ Isolation + Identity (Kata + Kagenti)
Sprint 4 ░░░░░░░░░░░░░░░░░░░░ Governance (MCP Gateway)
Sprint 5 ░░░░░░░░░░░░░░░░░░░░ CI/CD + End-to-end integration
```

For completed work, see [CHANGELOG.md](CHANGELOG.md).

**Conventions:** `[ ]` = pending | `[!]` = blocked | **Gate** = criterion required to proceed

---

## Sprint 2 — Remaining Work

> **Goal:** Guardrails intercepting requests. Coder running with functional workspaces. UI and multi-agent validation complete.
>
> **PRD Phases:** 7 (done), 2, 3

### claude-devtools validation

- [ ] Validate context reconstruction (token attribution per turn in 7 categories)
- [ ] Validate compaction visualization (exact moment + what was lost)
- [ ] Validate tool call inspector (inline diffs, syntax highlighting, bash output)
- [ ] Validate subagent trees (recursive execution trees with tokens, duration, cost)
- [ ] Test multi-session side-by-side for multi-agent scenarios

### agents-observe remaining

- [ ] Validate subagent hierarchy in dashboard (parent/child tracking visual)
- [ ] Test with long sessions (SQLite ephemeral stability)
- [ ] Evaluate event persistence via PVC (currently `/tmp`, data lost on restart)

### Multi-agent orchestration

- [ ] Inter-agent communication (shared context, message passing)
- [ ] Agent scheduling and prioritization in the cluster
- [ ] Per-agent isolation (each in its own pod/microVM)
- [ ] Cross-agent observability (distributed traces, aggregated cost)
- [ ] Evaluate community projects:
  - [Aperant](https://github.com/AndyMik90/Aperant) — Electron, up to 12 agents in parallel git worktrees
  - [claude_code_agent_farm](https://github.com/Dicklesworthstone/claude_code_agent_farm) — 20+ parallel agents with lock coordination
  - [claude-code-workflow-orchestration](https://github.com/barkain/claude-code-workflow-orchestration) — Multi-step plugin with specialized delegation
  - [gastown](https://github.com/gastownhall/gastown) — Multi-agent workspace manager
  - [harness](https://github.com/revfactory/harness) — Meta-skill that generates domain-specific agent teams

### Multi-agent task management exploration

> **Problem:** Running multiple agents is one thing. Deciding *what* each agent works on, tracking progress, and ensuring specs are followed before code starts — that's the missing layer. Evaluate community approaches to agent task management and spec-driven development.

**Category A — Task management and orchestration:**

- [ ] Evaluate [agi-le](https://github.com/gsampaio-rh/agi-le) (Python, file-based, agent-agnostic)
  - Spec-driven project management: epics → stories → tasks, file-based state (`.agile/`), hexagonal architecture
  - Agent Skill integration (SKILL.md standard), scheduler, conflict detection, handoff
  - Our own project — test with Claude Code on a real feature
- [ ] Evaluate [vibe-kanban](https://github.com/BloopAI/vibe-kanban) (Rust + TypeScript, 25.1k stars, Apache-2.0)
  - Kanban board for coding agents: plan with issues, run agents in workspaces, review diffs inline
  - Supports 10+ agents (Claude Code, Codex, Gemini CLI, Copilot, Amp, Cursor, etc.)
  - Self-hostable (Docker, Caddy), MCP server built-in, git worktree per workspace
- [ ] Evaluate [gastown](https://github.com/gastownhall/gastown) (Go, 14.1k stars, MIT)
  - Multi-agent workspace manager: Mayor (AI coordinator), Polecats (workers), Convoys (work tracking)
  - Git worktree persistence, merge queue (Refinery), three-tier health monitoring, OTEL telemetry
  - Scheduler with capacity limits, federated work coordination (Wasteland)

**Category B — Spec-driven development:**

- [ ] Evaluate [OpenSpec](https://github.com/Fission-AI/OpenSpec) (TypeScript, 40.2k stars, MIT)
  - Spec framework: propose → specs → design → tasks, artifact-guided workflow
  - Supports 25+ AI tools via slash commands, iterative not waterfall
- [ ] Evaluate [spec-kit](https://github.com/github/spec-kit) (Python, GitHub official)
  - Spec-driven development toolkit: constitution → specify → plan → tasks → build
  - Phase-gated lifecycle, Python CLI (`specify`), extensible via presets and extensions

**Evaluation criteria:**

- [ ] Test each tool with Claude Code + vLLM on a real feature (e.g., add PVC persistence to agents-observe)
- [ ] Compare: how well does each tool structure work for an AI agent vs a human?
- [ ] Assess OpenShift compatibility (containerizable? rootless? file-based state vs DB?)
- [ ] Document findings and recommendation in ADR

### Model upgrade: gpt-oss-20b

- [ ] Benchmark: compare latency and quality vs Qwen 2.5 14B

### 2.2 TrustyAI Guardrails (Phase 2)

- [ ] Install Red Hat OpenShift AI Operator
- [ ] Enable TrustyAI in DataScienceCluster (`managementState: Managed`)
- [ ] Deploy Guardrails Orchestrator CRD in `inference` namespace
- [ ] Configure PII detector: email, phone, SSN, credit card, IP (regex)
- [ ] Configure basic content filtering detector
- [ ] Validate: request with PII returns `400 Blocked`
- [ ] Validate: clean request passes through to vLLM

**Artifacts:**

```
guardrails/
├── manifests/
│   ├── guardrails-orchestrator.yaml
│   ├── orchestrator-config.yaml
│   └── gateway-config.yaml
├── scripts/
```

### 2.3 NeMo Guardrails (Phase 2 — optional, tech preview)

- [ ] Deploy NeMo Guardrails in `inference` namespace
- [ ] Create basic Colang rules (jailbreak, prompt injection)
- [ ] Configure chain: Agent → TrustyAI → NeMo → vLLM
- [ ] Validate output rails (PII leak prevention in response)

**Artifacts:**

```
infra/nemo/
├── deployment.yaml
└── colang-rules/
    ├── input-rails.co
    └── output-rails.co
```

### 2.3a Migrate standalone to Guardrails

- [ ] Update ConfigMap `claude-code-config`: `ANTHROPIC_BASE_URL` → Guardrails endpoint
- [ ] Restart standalone pod
- [ ] Validate: Claude Code responds via Guardrails → vLLM
- [ ] Validate: PII blocked on standalone too

### 2.4 Coder as CDE (Phase 3)

- [ ] Deploy PostgreSQL via OperatorHub in `coder` namespace
- [ ] Helm install Coder v2 with SecurityContext compatible with `restricted-v2`
- [ ] Create OpenShift Route with TLS termination
- [ ] Configure OIDC auth (OpenShift OAuth)
- [ ] Create Terraform template reusing ConfigMap `claude-code-config`:
  - Same custom image (UBI9 + Claude Code) already validated
  - Git + dev tools
  - `envFrom: configMapRef: claude-code-config`
- [ ] Validate: dev accesses Coder UI, creates workspace, Claude Code responds

**Artifacts:**

```
coder/
├── postgres/
│   └── postgres.yaml
├── helm/
│   └── values.yaml
├── route.yaml
├── oauth/
│   └── oidc-config.yaml
└── templates/
    └── claude-workspace/
        ├── main.tf
        └── variables.tf
```

### Sprint 2 Gate

| # | Criterion | Status |
|---|-----------|--------|
| G2.1 | Tool call traces appear in MLflow (AC-6) | PASS |
| G2.2 | MLflow receiving traces via `mlflow autolog claude` | PASS |
| G2.3 | Data captured: prompts, tokens, latency, tools | PASS |
| G2.4 | Request with PII blocked by TrustyAI (AC-5) | PENDING |
| G2.5 | Clean request reaches vLLM via Guardrails | PENDING |
| G2.6 | Coder UI accessible via Route with TLS | PENDING |
| G2.7 | Dev creates workspace and Claude Code works (AC-1) | PENDING |
| G2.8 | OIDC auth works (login via OpenShift) | PENDING |
| G2.9 | claude-devtools accessible via Route with session visible | PASS |
| G2.10 | Context reconstruction shows token breakdown per turn | PENDING |
| G2.11 | Multi-agent teams enabled and functional | PASS |
| G2.12 | gpt-oss-20b serving and agent conversing | PASS |
| G2.13 | Community reference projects evaluated and documented | PASS |
| G2.14 | Task management / spec-driven tools evaluated with ADR | PENDING |

---

## Sprint 3 — Isolation + Identity

> **Goal:** Workspaces running in Kata VMs. Agents with SPIFFE identity.
>
> **PRD Phases:** 4, 5

### 3.1 Kata Containers (Phase 4)

Kata was pulled forward to Sprint 1 and is complete. One remaining item:

- [ ] Update Coder Terraform template: `runtimeClassName: kata`

### 3.2 Kagenti + SPIFFE (Phase 5)

- [ ] Deploy SPIRE server in `agentops` namespace
- [ ] Deploy Kagenti Operator in `agentops` namespace
- [ ] Configure labels `kagenti.io/type: agent` on workspace pods
- [ ] Validate auto-discovery: Kagenti detects labeled pods
- [ ] Validate sidecar injection: `spiffe-helper` and `kagenti-client-registration`
- [ ] Validate SVID on pod filesystem
- [ ] Deploy Keycloak (or use existing)
- [ ] Configure token exchange: SVID → OAuth2 token with claims (role, namespace, agent-id)

**Artifacts:**

```
agentops/
├── spire/
│   ├── server.yaml
│   ├── agent.yaml
│   └── registration-entries.yaml
├── kagenti/
│   ├── operator.yaml
│   └── agentcard-sample.yaml
└── keycloak/
    ├── deployment.yaml
    └── realm-config.json
```

### Sprint 3 Gate

| # | Criterion | Validation |
|---|-----------|------------|
| G3.1 | `uname -r` inside workspace != host (AC-2) | Exec in pod |
| G3.2 | NetworkPolicy blocks unauthorized access (AC-8) | `curl` to blocked service → timeout |
| G3.3 | SVID present on pod filesystem (AC-3) | `ls /run/spire/sockets/` |
| G3.4 | Token exchange works: SVID → JWT with claims | Test via Keycloak |
| G3.5 | Kagenti creates AgentCard automatically | `oc get agentcards -n agent-sandboxes` |

---

## Sprint 4 — Governance

> **Goal:** Tools governed by identity.
>
> **PRD Phase:** 6

### 4.1 MCP Gateway (Phase 6)

- [ ] Install Sail Operator (Istio) via OperatorHub
- [ ] Install Gateway API CRDs
- [ ] Deploy MCP Gateway (Envoy-based) via Helm in `mcp-gateway` namespace
- [ ] Configure MCP server backends: GitHub, filesystem
- [ ] Install Kuadrant + Authorino
- [ ] Configure AuthPolicy: JWT validation from Keycloak tokens
- [ ] Define OPA policies per role:
  - `developer`: filesystem read/write, github read
  - `senior-developer`: developer + github create_pr
  - `admin`: full access
- [ ] Configure Claude Code: `MCP_URL` points to gateway
- [ ] Validate: tool list filtered by token role
- [ ] Validate: unauthorized tool call returns 403

**Artifacts:**

```
mcp-gateway/
├── helm/
│   └── values.yaml
├── gateway-api/
│   ├── gateway.yaml
│   └── httproute.yaml
├── auth/
│   ├── authpolicy.yaml
│   ├── authorino.yaml
│   └── opa-policies/
│       ├── developer.rego
│       └── admin.rego
└── mcp-servers/
    ├── github.yaml
    └── filesystem.yaml
```

### Sprint 4 Gate

| # | Criterion | Validation |
|---|-----------|------------|
| G4.1 | Tools filtered by token role in MCP Gateway (AC-4) | `tools/list` with different role tokens |
| G4.2 | Unauthorized tool call returns 403 | `tools/call` with unprivileged token |

---

## Sprint 5 — CI/CD + Integration

> **Goal:** Safety scan pipeline. End-to-end test of the full stack.
>
> **PRD Phases:** 8 + integration

### 5.1 Tekton + Garak (Phase 8)

- [ ] Install Tekton Pipelines Operator via OperatorHub
- [ ] Create Task `garak-scan`: run Garak adversarial probes against vLLM
- [ ] Create Task `agent-deploy`: deploy agent via Kagenti
- [ ] Create Task `smoke-test`: basic post-deploy validation
- [ ] Create Pipeline: `garak-scan` → `agent-deploy` → `smoke-test`
- [ ] Configure triggers (EventListener + TriggerTemplate)
- [ ] Validate: pipeline blocks deploy when Garak detects vulnerability
- [ ] Validate: pipeline allows deploy when scan passes

**Artifacts:**

```
cicd/
└── tekton/
    ├── tasks/
    │   ├── garak-scan.yaml
    │   ├── agent-deploy.yaml
    │   └── smoke-test.yaml
    ├── pipelines/
    │   └── agent-safety-pipeline.yaml
    └── triggers/
        ├── event-listener.yaml
        └── trigger-template.yaml
```

### 5.2 End-to-end integration

- [ ] Full E2E test:
  1. Dev accesses Coder → creates workspace
  2. Workspace runs in Kata VM
  3. Claude Code uses local model via Guardrails
  4. Tools accessed via MCP Gateway (filtered by role)
  5. Traces appear in MLflow
  6. PII blocked by TrustyAI
- [ ] Validate all acceptance criteria (AC-1 through AC-8)
- [ ] Measure success metrics (PRD section 10)
- [ ] Document results and gaps

### 5.3 Housekeeping

- [ ] Review and update docs with learnings
- [ ] Document troubleshooting / runbook

### Sprint 5 Gate

| # | Criterion | Validation |
|---|-----------|------------|
| G5.1 | Tekton pipeline runs Garak and blocks vulnerable model (AC-7) | PipelineRun with intentional failure |
| G5.2 | E2E flow works: Coder → Kata → Guardrails → vLLM → MCP → MLflow | Full manual test |
| G5.3 | All 8 acceptance criteria pass | Checklist |
| G5.4 | Metrics documented vs PRD targets | `docs/results/metrics.md` |

---

## Post-PoC — Dev Spaces (Phase 9)

> **Goal:** Alternative to Coder using Dev Spaces. Not blocking for PoC.

- [ ] Install Dev Spaces Operator
- [ ] Create Devfile with Claude Code + tooling
- [ ] Integrate with existing vLLM / MCP Gateway / MLflow
- [ ] Compare DX: Coder vs Dev Spaces

---

## Post-PoC — Agent Orchestration Governance (Phase 10)

> **Goal:** Evaluate multi-agent orchestration tools and define governance layer for coordinating agents at scale.
>
> **Reference:** [Gastown](https://github.com/gastownhall/gastown) | [Multica](https://github.com/multica-ai/multica)

### 10.1 Research and Evaluation

- [ ] Deploy [Gastown](https://github.com/gastownhall/gastown) locally (Go, 14k stars)
  - Mayor (AI coordinator), Polecats (worker agents), Convoys (work tracking)
  - Hooks (git worktree persistence), Refinery (merge queue), OTEL telemetry
- [ ] Deploy [Multica](https://github.com/multica-ai/multica) locally (Next.js + Go + PostgreSQL, 12.2k stars)
  - Agents as teammates (board/assignment), reusable skills, CLI daemon
- [ ] Test both with Claude Code + local vLLM
- [ ] Evaluate against AgentOps requirements:
  - OpenShift compatibility (SCC, NetworkPolicy, rootless)
  - Kata integration (runtimeClassName per agent)
  - SPIFFE/Kagenti integration (identity per agent)
  - MLflow integration (multi-agent traces)
  - TrustyAI compatibility (guardrails per request, not per agent)
- [ ] Compare orchestration models:
  - Gastown: Mayor/convoy (AI coordinator, git-backed state, merge queue)
  - Multica: Board/assignment (human-driven, skills reuse, WebSocket streaming)
- [ ] Document findings in ADR

### 10.2 Orchestration PoC on OpenShift

- [ ] Containerize selected tool (or hybrid) with UBI base image
- [ ] Adapt for SCC `restricted-v2` (rootless, read-only rootfs)
- [ ] Deploy in `agentops` namespace
- [ ] Integrate with existing stack (vLLM, Kata, MCP Gateway, MLflow)
- [ ] Test multi-agent workflows (2-5 simultaneous agents)
- [ ] Validate health monitoring at scale (5-10 concurrent agents)
- [ ] Measure orchestration overhead (latency, resource usage)

**Artifacts:**

```
orchestration/
├── manifests/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   └── pvc.yaml
├── scripts/
│   ├── 00-prerequisites.sh
│   ├── 01-deploy.sh
│   └── 99-verify.sh
└── policies/
    ├── capacity.yaml
    ├── assignment.yaml
    └── escalation.yaml
```

### 10.3 Governance Layer

- [ ] Define capacity policies (max concurrent agents, resource quotas, vLLM rate limiting)
- [ ] Define work assignment rules (role-based, skill-based, priority queues)
- [ ] Define escalation policies (human-in-the-loop gates, timeout escalation, severity routing)
- [ ] Implement audit trail (who assigned what, outcomes, tokens consumed, MLflow integration)
- [ ] Integrate with Kagenti identity (SPIFFE SVID per agent, MCP Gateway policies per agent)

### Post-PoC Gate — Orchestration

| # | Criterion | Validation |
|---|-----------|------------|
| G10.1 | Tool evaluated and ADR documented | ADR with decision rationale |
| G10.2 | Orchestrator running on OpenShift with 2+ simultaneous agents | `oc get pods -n agentops` |
| G10.3 | Agents isolated in Kata with individual SPIFFE identity | Unique SVID per agent |
| G10.4 | Work distribution functional (task → agent → result) | E2E with 3+ parallel tasks |
| G10.5 | Capacity policies enforced (max agents, rate limit) | Overflow test |
| G10.6 | Complete audit trail in MLflow | Traces with agent-id, task-id, outcome |

---

## Sprint Dependencies

```mermaid
flowchart LR
    S1["Sprint 1\nInfra + vLLM\n+ Claude standalone"] --> S2["Sprint 2\nObservability +\nSafety + Coder"]
    S2 --> S3["Sprint 3\nKata + Kagenti"]
    S3 --> S4["Sprint 4\nMCP Gateway"]
    S4 --> S5["Sprint 5\nCI/CD + E2E"]
    S5 --> PostPoC["Post-PoC\nDev Spaces +\nAgent Orchestration"]

    S1 -->|"vLLM + agent validated"| S2
    S2 -->|"MLflow + Guardrails + Coder"| S3
    S3 -->|"SPIFFE tokens"| S4
    S4 -->|"Full stack"| S5
    S5 -->|"Stack validated E2E"| PostPoC
```

**Critical dependencies:**
- Sprint 2 depends on vLLM + standalone agent validated (Sprint 1 — done)
- Sprint 3 depends on Coder functional (Sprint 2) to test Kata in workspaces
- Sprint 4 depends on SPIFFE tokens (Sprint 3) for MCP Gateway authentication
- Sprint 5 is integration — depends on everything
- Post-PoC (Orchestration) depends on full stack validated (Sprint 5)

---

## Risks

| Sprint | Risk | Mitigation |
|--------|------|------------|
| 2 | MLflow storage insufficient for traces | Monitor PVC usage; expand or use S3 |
| 2 | Coder SCC conflicts with restricted-v2 | Follow official docs; test with anyuid if needed |
| 2 | TrustyAI high latency | Measure; disable heavy detectors |
| 3 | Kagenti alpha — breaking changes | Pin version; maintain manual workaround |
| 4 | MCP Gateway tech preview — unstable | Pin version; static config as fallback |
| 5 | Garak scan takes too long | Limit probes; pipeline timeout |
| Post-PoC | Gastown/Multica incompatible with OpenShift SCC | Test rootless; adapt Dockerfile with UBI base |
| Post-PoC | Resource contention with multiple agents | Scheduling policies; rate limiting in orchestrator |
| Post-PoC | Merge conflicts between agents on same repo | Merge queue (Refinery pattern); file locks; task partitioning |
