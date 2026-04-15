# ADR-023: Internal Registry Builds for Community Sidecars

**Status:** Accepted
**Date:** 2026-04-14
**Deciders:** Platform Engineering

## Context

The agent pod runs community-maintained sidecars (claude-devtools, agents-observe)
alongside the main Claude Code container. The initial approach for claude-devtools
pulled its image directly from GHCR (`ghcr.io/matt1398/claude-devtools:latest`).

This has problems in an enterprise/air-gapped context:

1. **External dependency at deploy time** — pod scheduling fails if GHCR is
   unreachable or rate-limited
2. **No control over image contents** — upstream can push breaking changes or
   vulnerable layers at any time
3. **Cannot apply patches** — agents-observe required a WebSocket protocol fix
   (`ws://` → `wss://`) for OpenShift edge TLS termination. Impossible with an
   external pre-built image.
4. **Quota compliance** — OpenShift ResourceQuotas require resource limits on all
   containers, including build pods. External images skip the build pipeline
   entirely, but internal builds need explicit resource specs.

## Decision

Build all community sidecar images from source using **OpenShift BuildConfigs**
that clone the upstream Git repository and produce images in the **internal
registry** (`image-registry.openshift-image-registry.svc:5000`).

### Build Strategy

Each sidecar gets a BuildConfig + ImageStream pair:

| Sidecar | Source | Build Type | Manifests |
|---------|--------|-----------|-----------|
| claude-devtools | `github.com/matt1398/claude-devtools` (main) | Docker (upstream Dockerfile) | `agents/claude-devtools/manifests/build.yaml` |
| agents-observe | `github.com/simple10/agents-observe` (main) | Docker (patched via Binary source) | `agents/agents-observe/manifests/build.yaml` |

**agents-observe** uses a Binary source with a custom Dockerfile that:
1. Clones the upstream repo in a `source` stage
2. Patches `use-websocket.ts` to use protocol-aware WebSocket URLs
3. Builds the client and server in a `builder` stage
4. Produces a production image with writable `/app/data` for SQLite

**claude-devtools** uses a Git source directly (no patches needed).

### Resource Limits

BuildConfigs include explicit resource requests/limits to satisfy the namespace
ResourceQuota:

```yaml
resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    cpu: "2"
    memory: 4Gi
```

### Rebuild Process

```bash
# Rebuild devtools (upstream Dockerfile, no patches)
oc start-build claude-devtools -n agent-sandboxes --follow

# Rebuild agents-observe (patched Dockerfile)
oc start-build agents-observe -n agent-sandboxes \
  --from-dir=<dir-with-Dockerfile> --follow

# Roll out new images
oc rollout restart deployment/claude-code-standalone -n agent-sandboxes
```

## Consequences

**Positive:**
- Images are stored in the internal registry — no external pull dependency
- Patches can be applied at build time (WSS fix, permission fixes)
- Build resources are quota-compliant
- Image provenance is auditable via BuildConfig history
- Enables air-gapped deployments (Git source can be mirrored)

**Negative:**
- Initial build takes 1-2 minutes (npm install + compile)
- Upstream updates require manual rebuild (`oc start-build`)
- Binary source builds (agents-observe) need local Dockerfile context

**Future:**
- Automate rebuilds via GitHub webhook triggers or periodic CronJob
- Mirror upstream repos for true air-gap support
- Consider `Tekton Pipeline` for multi-step builds with integration tests

## Alternatives Considered

| Approach | Why Not |
|----------|---------|
| Pull from GHCR/DockerHub | External dependency, no patch capability, rate limits |
| Fork + modify upstream | Maintenance burden, drift from upstream |
| Vendor source in-repo | User rejected this approach ("I don't like this and I don't think it's feasible") |
| Buildah/Kaniko external | Over-engineered for PoC, OpenShift BuildConfigs are native |
