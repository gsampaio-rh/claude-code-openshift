# ADR-030: Context Window Expansion and Model Evaluation

**Status:** Accepted
**Date:** 2026-04-23
**Deciders:** AgentOps team

## Context

Claude Code's system prompt consumes ~16K tokens. With `--max-model-len=32768`, only ~16K remained for user content and output. A 22KB document (`doc.md`, ~35K tokens with system prompt) caused `Input length (34842) exceeds model's maximum context length (32768)`.

The gpt-oss-20b model (21B MoE, 3.6B active params) natively supports **128K tokens** — the 32K limit was inherited from the earlier Qwen 2.5 14B configuration.

### Options Considered

1. **Increase gpt-oss-20b `--max-model-len` to 65536** — model weights ~15GB, leaves ~28GB for KV cache on L40S 48GB. Safe and proven.

2. **Migrate to Qwen3-Coder-Next AWQ 4-bit** (80B MoE / 3B active, 256K context) — higher coding index (22.9 vs 18.5), purpose-built for agentic coding. However, 512 experts × AWQ 4-bit = ~48GB of weights alone, leaving zero room for KV cache on a single L40S.

3. **Migrate to Devstral Small 2** (24B dense, 256K context, 65.8% SWE-bench) — best SWE-bench in its weight class, ~14GB FP8. Viable fallback but less tested with Claude Code's Anthropic Messages API.

## Decision

**Option 1: expand gpt-oss-20b to 65K context.** Also increase `CLAUDE_CODE_MAX_OUTPUT_TOKENS` from 8192 to 16384 (16K system + 16K output = 32K, within 65K).

Keep Qwen3-Coder-Next manifest at `replicas: 0` as a reference for future multi-GPU deployment.

## Rationale

- Zero infrastructure change — same GPU, same model, just a config bump
- Proven: community reports gpt-oss-20b stable at 60K on single L40S
- Doubles both input capacity and output quality
- Qwen3-Coder-Next is the better long-term model but requires 2x L40S with tensor parallelism

## Trade-offs

- 65K is half of gpt-oss-20b's native 128K — pushing to 128K might work but reduces KV cache headroom for concurrent requests
- gpt-oss-20b (coding index 18.5) is a generalist, not a coding specialist — Qwen3-Coder-Next (22.9) or Devstral Small 2 (65.8% SWE-bench) would be better for pure coding tasks
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384` with a ~35K input doc leaves only ~14K tokens of headroom before hitting 65K

## Consequences

- `inference/vllm/manifests/gpt-oss-20b-deployment.yaml`: `--max-model-len=32768` → `65536`
- `claude-code-config` ConfigMap: `CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192` → `16384`
- New manifest `inference/vllm/manifests/qwen3-coder-next-deployment.yaml` at `replicas: 0` for future use
- Future: provision 2x L40S (g6e.8xlarge or 2x g6e.4xlarge) to run Qwen3-Coder-Next with tensor parallelism
