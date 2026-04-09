# ADR-018: SELinux Bug in Sandboxed Containers Operator 1.3.3

**Status:** Open (workaround documented, fix pending)
**Date:** 2026-04-09
**Deciders:** Platform Engineering

## Context

After installing the OpenShift Sandboxed Containers Operator (v1.3.3, `stable-1.3`) on OpenShift 4.20, the `osc-monitor` DaemonSet pods crash with:

```
Error: container create failed: write to `/proc/self/attr/keycreate`: Invalid argument
```

This affects the `openshift-sandboxed-containers-monitor` pods on 2 of 3 nodes. The `controller-manager` pod also exhibits frequent restarts (22+).

### Root Cause

The operator images are built on RHEL 8 (`osc-monitor-rhel8:1.3.3`, `osc-rhel8-operator`). OpenShift 4.20 runs RHEL 9.6 (kernel 5.14.0-570). The SELinux context operation `keycreate` behaves differently between RHEL 8 and RHEL 9 kernels — the RHEL 8 binary attempts to write a SELinux context that the RHEL 9 kernel rejects.

### Impact

- **Kata runtime itself is NOT affected** — the `kata-runtime` binary and `containerd-shim-kata-v2` are installed via MachineConfig (not the monitor pods)
- **MCP `kata-oc` works correctly** — nodes get the Kata runtime and reboot successfully
- **RuntimeClass `kata` is created** and pods with `runtimeClassName: kata` work
- **Only monitoring/observability is degraded** — the `osc-monitor` DaemonSet collects metrics about Kata pods

### Nodes Affected

| Node | Instance | Monitor Pod | Status |
|---|---|---|---|
| ip-10-0-30-160 | g6.4xlarge (control-plane) | `d9585` | `CreateContainerError` |
| ip-10-0-11-255 | m6a.4xlarge (worker) | `n72ck` | Running |
| ip-10-0-95-106 | m5.metal (bare metal) | `tzkpg` | `CreateContainerError` |

## Decision

Accept the monitor pod failures as a known issue. Do not attempt to fix — the operator version (1.3) is on a stable channel and will be upgraded when a compatible version is available.

### Remediation Plan

1. **Short-term**: Tolerate the failing monitor pods. They don't affect Kata runtime or agent workloads.
2. **Medium-term**: Upgrade to Sandboxed Containers Operator **1.5+** when available in OperatorHub. Version 1.5 includes:
   - RHEL 9 based images (compatible with OCP 4.20)
   - peer-pods support (eliminates bare metal requirement)
3. **Long-term**: Report bug to Red Hat if not already tracked.

### Verification

```bash
# Verify Kata runtime works despite monitor failures
oc get runtimeclass kata
oc get mcp kata-oc
oc get kataconfig cluster-kataconfig -o jsonpath='{.status.installationStatus}'

# Check which monitor pods are affected
oc get pods -n openshift-sandboxed-containers-operator
```

## Consequences

### Positive
- Kata runtime is fully functional for agent pods
- No action required from platform team

### Negative
- Missing telemetry from osc-monitor on affected nodes
- Noisy alerts if monitoring is configured for the operator namespace
- Controller-manager restarts may cause brief reconciliation delays for KataConfig changes
