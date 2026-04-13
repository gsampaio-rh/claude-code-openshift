# ADR-014: PVC for vLLM Model Cache

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

The Qwen 2.5 14B FP8-dynamic model is ~7GB compressed, expanding to ~16GB with HuggingFace cache metadata on disk. vLLM downloads the model from HuggingFace on startup via `--download-dir=/mnt/models`.

The initial deployment used an `emptyDir` volume (30Gi, `sizeLimit`). This meant every pod restart — rollout, node drain, OOM kill, GPU error — triggered a fresh download taking 5-10 minutes, during which the `startupProbe` window (10 min) was consumed.

On a single-GPU cluster with no redundancy, this creates unacceptable downtime for every deployment change.

## Decision

Replace the `emptyDir` with a **PersistentVolumeClaim** (30Gi, `gp3-csi`, `ReadWriteOnce`).

## Rationale

- **Restart resilience**: Model persists across pod restarts. Cold start drops from ~6 min (download + load) to ~2 min (GPU load only).
- **Rollout safety**: `Deployment` rollout can terminate old pod and start new pod without re-downloading. The `startupProbe` window is consumed by GPU loading, not network I/O.
- **Bandwidth**: Avoids repeated downloads of 7GB+ from HuggingFace CDN, relevant for metered egress or rate-limited environments.

## Trade-offs

| Aspect | emptyDir | PVC (gp3-csi) |
|---|---|---|
| Startup after restart | ~6 min (download + load) | ~2 min (load only) |
| Storage provisioner dependency | None | Requires CSI driver (gp3-csi on AWS) |
| Multi-replica | Each replica downloads independently | RWO limits to single replica per node |
| Cleanup | Automatic on pod delete | Manual PVC delete or `reclaimPolicy` |
| Cost | Free (node ephemeral storage) | EBS volume cost (~$2.40/month for 30Gi gp3) |

## Manifest

```yaml
# inference/vllm/manifests/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qwen25-14b-model-cache
  namespace: inference
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: gp3-csi
  resources:
    requests:
      storage: 30Gi
```

The `Deployment` references it via `persistentVolumeClaim.claimName`.

## Consequences

- `storageClassName: gp3-csi` is AWS-specific — other clusters need adjustment
- Multi-replica scaling requires `ReadWriteMany` (EFS) or per-replica PVCs
- Model updates (new HF revision) require either PVC delete+recreate or a manual cache clear inside the pod
- The `kustomization.yaml` now includes `pvc.yaml` before `deployment.yaml` to ensure PVC exists before the Deployment references it
