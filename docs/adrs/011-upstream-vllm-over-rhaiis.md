# ADR-011: Upstream vLLM over RHAIIS for Model Serving

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

Claude Code communicates with the model server using the **Anthropic Messages API** (`/v1/messages`). This is the same protocol Claude Code uses with Anthropic's cloud — making vLLM a transparent drop-in.

The initial plan was to use **Red Hat AI Inference Server (RHAIIS)** — Red Hat's downstream build of vLLM — because it ships as a certified image (`registry.redhat.io/rhaiis/vllm-cuda-rhel9`) with OpenShift support.

During deployment we discovered that RHAIIS 3.2.4 (vLLM 0.11.0+rhai5) **strips the Anthropic Messages API entirely** from its build. The `/v1/messages` route does not exist — only `/v1/chat/completions` (OpenAI API) is available.

**Evidence:**

```
# Inside RHAIIS pod:
$ python3 -c "import vllm; print(vllm.__version__)"
0.11.0+rhai5

# Checking source:
$ python3 -c "
with open('.../api_server.py') as f:
    print('messages' in f.read().lower(), 'anthropic' in f.read().lower())
"
False False
```

No route for `/v1/messages` appeared in the server logs.

## Decision

Use **upstream vLLM** (`vllm/vllm-openai:v0.19.0`) instead of RHAIIS for model serving.

## Rationale

- **Anthropic Messages API required**: Claude Code speaks the Anthropic protocol natively. Without `/v1/messages`, we'd need a translation proxy (additional complexity, latency, failure point).
- **Upstream v0.19.0 has it**: The Anthropic Messages API was added in vLLM PR #22627 (merged Oct 2025). Upstream v0.19.0 includes `/v1/messages` and `/v1/messages/count_tokens`.
- **No code changes needed in Claude Code**: With the Anthropic API available, `ANTHROPIC_BASE_URL` points directly to vLLM. No adapter or shim layer.
- **Same model compatibility**: `RedHatAI/Qwen2.5-14B-Instruct-FP8-dynamic` loads identically on both RHAIIS and upstream vLLM.

## Trade-offs

| Aspect | RHAIIS | Upstream vLLM |
|---|---|---|
| Red Hat support | Fully supported, certified | Community support only |
| Anthropic Messages API | Missing | Available |
| OpenShift compatibility | Native (runs as non-root) | Needs env var overrides for cache dirs |
| Image registry | `registry.redhat.io` (authenticated) | `docker.io/vllm` (public) |
| Update cadence | Quarterly releases | Monthly+ releases |

## OpenShift Compatibility Fixes

Upstream vLLM assumes writable `/.cache` and `$HOME`. OpenShift runs with random UIDs. Required env overrides:

```yaml
env:
  - name: HF_HOME
    value: /mnt/models
  - name: XDG_CACHE_HOME
    value: /mnt/models/.cache
  - name: HOME
    value: /mnt/models
  - name: NUMBA_CACHE_DIR
    value: /tmp/numba_cache
  - name: TRITON_CACHE_DIR
    value: /tmp/triton_cache
```

Plus a writable `/tmp` volume mount.

## Consequences

- Model serving uses an uncertified image — acceptable for PoC, revisit for production
- If RHAIIS adds Anthropic Messages API in a future release, we can switch back
- The `infra/vllm/manifests/deployment.yaml` pins the upstream image version explicitly
- Validation script `infra/vllm/scripts/02-validate-model.sh` checks for `/v1/messages` availability
