# ADR-007: Garak in Tekton Pipeline for Pre-Deploy Safety Scanning

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

Models deployed for agent use may have vulnerabilities — susceptibility to jailbreaks, prompt injection, or producing harmful outputs. These should be caught before the model goes live, not after.

Options:

1. **Manual testing** — security team manually tests models before deployment
2. **Garak in CI/CD pipeline** — automated adversarial scanning as a pipeline gate
3. **No pre-deploy scanning** — rely only on runtime guardrails (TrustyAI/NeMo)

## Decision

Use **Garak** as an automated adversarial scanner in a **Tekton Pipeline** that gates model/agent deployment.

## Rationale

- **Shift-left safety**: catch vulnerabilities before they reach production, not after. Runtime guardrails (ADR-005) are defense-in-depth, not the only defense.
- **Automated and repeatable**: Tekton pipeline runs Garak automatically when model or agent configuration changes. No manual testing bottleneck.
- **Garak is comprehensive**: tests for jailbreaks, prompt injection, encoding attacks, and other adversarial vectors at the model level.
- **Pipeline as gate**: if Garak scan fails, deployment is blocked. Model cannot be promoted without passing safety checks.
- **Part of Red Hat AI roadmap**: Garak integration via TrustyAI Operator and EvalHub is planned for Red Hat AI.

## Pipeline Design

```
Trigger (model/config change)
  --> Garak Scan Task (adversarial probes against model endpoint)
  --> Decision Gate (pass/fail based on threshold)
  --> Agent Deploy Task (deploy via Kagenti if pass)
  --> Smoke Test Task (basic functional validation)
  --> Rollback (if smoke test fails)
```

## Trade-offs

- **Garak is planned, not GA**: may require running the upstream open-source version directly until Red Hat AI integration is available.
- **Scan duration**: adversarial scanning can take 10-30 minutes depending on probe count. Pipeline is not instant.
- **False positives**: some probes may flag benign model behavior. Threshold tuning required.
- **GPU usage during scan**: Garak sends many prompts to the model, consuming GPU time. Should run during low-usage periods or on a separate model instance.

## Consequences

- Tekton Pipelines Operator must be installed
- Garak Task created in `cicd` namespace
- Agent Deploy Task created using Kagenti API
- Pipeline configured with trigger on model/config changes
- Pass/fail threshold defined (recommended: >90% pass rate for PoC)
- Results stored for compliance audit
