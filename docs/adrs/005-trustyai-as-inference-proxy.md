# ADR-005: TrustyAI as Inference Proxy Between Agent and Model

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

AI agents send prompts to the model that may contain PII, jailbreak attempts, or prompt injections. Model outputs may leak sensitive data. We need a safety boundary between the agent and the model.

Options:

1. **No guardrails** — agent talks directly to vLLM
2. **Application-level filtering** — add filtering logic inside the agent code
3. **TrustyAI Guardrails Orchestrator** — infrastructure-level proxy that screens inputs/outputs
4. **NeMo Guardrails** — programmable conversational rails with Colang

## Decision

Use **TrustyAI Guardrails Orchestrator** (GA) as the primary proxy, with **NeMo Guardrails** (Tech Preview) as a complementary layer. Agents never talk directly to vLLM.

## Rationale

- **Infrastructure-level, not application-level**: guardrails operate without modifying agent code (BYOA principle). The agent thinks it's talking to the model; it's actually talking to the Guardrails Orchestrator.
- **TrustyAI is GA in OpenShift AI 3.0**: production-supported, managed by the TrustyAI Operator.
- **Defense in depth**: TrustyAI handles PII detection (regex-based) and content filtering. NeMo adds programmable Colang rules for conversational safety. Two layers with different detection approaches.
- **Auditability**: all blocked/modified requests are logged for compliance review.

## Architecture

```
Agent --> ANTHROPIC_BASE_URL --> TrustyAI Guardrails --> NeMo Guardrails --> vLLM
```

The agent's `ANTHROPIC_BASE_URL` points to the Guardrails Orchestrator endpoint, not vLLM directly.

## Trade-offs

- **Latency**: every request goes through two additional services. Expected 50-200ms overhead depending on detector complexity.
- **False positives**: PII regex detectors may flag legitimate code (e.g., email validation patterns). Requires tuning.
- **NeMo is Tech Preview**: not production-supported. Colang rules need careful authoring.
- **Complexity**: requires OpenShift AI Operator, DataScienceCluster configuration, and KServe Raw Deployment mode.

## Detectors Configured

| Detector | Type | Layer |
|---|---|---|
| Email addresses | Regex PII | TrustyAI |
| Phone numbers | Regex PII | TrustyAI |
| Credit card numbers | Regex PII | TrustyAI |
| IP addresses | Regex PII | TrustyAI |
| Jailbreak patterns | Heuristic | NeMo (Colang) |
| Output PII leak | Regex | TrustyAI (output) |

## Consequences

- Red Hat OpenShift AI Operator must be installed
- TrustyAI enabled in DataScienceCluster (managementState: Managed)
- KServe configured for Raw Deployment mode
- Guardrails Orchestrator CRD deployed in `inference` namespace
- NeMo Guardrails deployed with Colang rules
- Agent `ANTHROPIC_BASE_URL` points to Guardrails, not vLLM
- False positive rate must be monitored and detectors tuned
