# ADR-012: Plain Deployment+Service over KServe for vLLM

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

The initial design used **KServe** (`ServingRuntime` + `InferenceService`) to deploy vLLM, leveraging OpenShift AI (RHOAI) for lifecycle management, autoscaling, and model storage initialization.

After switching to upstream vLLM (ADR-011), KServe became problematic:

1. **Image lock-in**: KServe `ServingRuntime` controls the vLLM container image. RHOAI's `ServingRuntime` catalog pins to RHAIIS images that lack the Anthropic Messages API.
2. **Startup complexity**: KServe adds an `storage-initializer` init container for model download. This works but adds a layer of indirection when debugging and customizing the model loading.
3. **HPA overhead**: KServe creates a `HorizontalPodAutoscaler` by default. For a PoC with a single GPU, this generates noise (`FailedGetResourceMetric` events).
4. **Probe mismatch**: KServe's built-in probes don't account for the long model download + GPU warmup time of large models, causing restart loops.

## Decision

Replace KServe `ServingRuntime` + `InferenceService` with a plain Kubernetes **Deployment** + **Service**.

## Rationale

- **Full control over image**: We pin `vllm/vllm-openai:v0.19.0` directly in the Deployment spec. No runtime catalog or operator overrides needed.
- **Startup probe**: A `startupProbe` with `failureThreshold: 60` (10 min tolerance) prevents restarts during model download without affecting steady-state health checks.
- **Simpler debugging**: `oc logs deploy/qwen25-14b` shows vLLM logs directly. No init containers, no sidecar indirection.
- **No wasted abstractions**: KServe's canary deployments, traffic splitting, and model mesh are not needed for a single-model PoC.

## Manifest Structure

```
infra/vllm/manifests/
├── deployment.yaml    # Deployment with vLLM container, GPU, probes
├── service.yaml       # ClusterIP Service on port 8080
└── kustomization.yaml # References deployment.yaml + service.yaml
```

Old KServe manifests (`servingruntime.yaml`, `inferenceservice.yaml`, `secret.yaml`) are no longer referenced in `kustomization.yaml`.

## Service Endpoint

| Before (KServe) | After (Deployment+Service) |
|---|---|
| `http://qwen25-14b-predictor.inference.svc.cluster.local:8080` | `http://qwen25-14b.inference.svc.cluster.local:8080` |

The ConfigMap `claude-code-config` was updated to use the shorter service name.

## Trade-offs

| Aspect | KServe | Plain Deployment |
|---|---|---|
| Autoscaling | Built-in HPA + scale-to-zero | Manual (not needed for PoC) |
| Canary / traffic split | Native | Not available |
| Model storage init | `storage-initializer` container | vLLM downloads via `--download-dir` |
| Probe flexibility | Limited by KServe defaults | Full control |
| Image control | Via ServingRuntime catalog | Direct in Deployment spec |
| RHOAI dashboard | Visible as InferenceService | Not visible (use `oc` CLI) |

## Consequences

- Model no longer appears in the RHOAI dashboard — acceptable for PoC
- Scaling, rollback, and update strategy are managed via standard Deployment semantics
- If KServe is needed later (production with autoscaling), migration is straightforward: re-create `ServingRuntime` + `InferenceService` with the upstream image
- Validation script `02-validate-model.sh` checks Deployment readiness instead of InferenceService status
