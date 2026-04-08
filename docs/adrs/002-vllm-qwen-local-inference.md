# ADR-002: vLLM with Qwen 2.5 14B for Local Inference

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

Claude Code needs a model to power its coding capabilities. Options:

1. **Anthropic API (cloud)** — use Claude models via API key
2. **Amazon Bedrock** — managed Claude access via AWS
3. **vLLM with open model (on-prem)** — serve an open-source coding model locally

## Decision

Use **vLLM** (via Red Hat AI Inference Server) serving **Qwen 2.5 14B Instruct** on the existing OpenShift cluster GPU.

## Rationale

- **Zero API cost**: no per-token charges. All inference runs on owned hardware.
- **Data stays on-prem**: prompts and responses never leave the cluster. Required for PoC validation of air-gapped feasibility.
- **vLLM exposes Anthropic-compatible API**: Claude Code connects via `ANTHROPIC_BASE_URL` without code changes.
- **Red Hat AI Inference Server is vLLM downstream**: supported, tested, has a Helm chart (`rhai-helm`).
- **Qwen 2.5 14B**: good balance of coding quality vs VRAM requirements. Runs on a single GPU with 12GB+ VRAM (quantized) or 28GB (FP16). Documented working with Claude Code in the Red Hat Developer article.

## Trade-offs

- **Quality gap vs Claude models**: Qwen 2.5 14B is not as capable as Claude Sonnet/Opus for complex coding tasks. Acceptable for PoC. Production may require larger models or hybrid approach (local for simple tasks, cloud API for complex ones).
- **GPU dependency**: requires at least one GPU node. Not all clusters have GPU.
- **Single point of failure**: one vLLM instance serves all agents. No HA in PoC scope.

## GPU Requirements

| Precision | VRAM | GPU Examples |
|---|---|---|
| FP16 | ~28GB | A100, H100 |
| Q8 | ~15GB | A10G, RTX 4090 |
| Q5_K_M | ~11GB | RTX 4060 Ti 16GB |

## Consequences

- NVIDIA GPU Operator and Node Feature Discovery must be installed
- vLLM deployment requires a GPU node with sufficient VRAM
- Claude Code env var `ANTHROPIC_BASE_URL` points to Guardrails (which proxies to vLLM), not directly to vLLM
- Model download from Hugging Face requires HF_TOKEN and network access during setup
