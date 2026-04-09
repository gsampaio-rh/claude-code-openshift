# ADR-017: Kata Containers Requires Bare Metal on AWS EC2

**Status:** Accepted
**Date:** 2026-04-09
**Deciders:** Platform Engineering
**Supersedes:** Updates ADR-001 (Kata for isolation) with implementation findings

## Context

ADR-001 selected Kata Containers for agent isolation. During Sprint 1 implementation on OpenShift 4.20 (AWS EC2), we discovered that Kata's QEMU hypervisor requires `/dev/kvm`, which is only available on bare metal EC2 instances.

### Validation Steps Performed

1. **Installed Sandboxed Containers Operator** (v1.3.3, `stable-1.3` channel)
2. **Created KataConfig CR** — MCP `kata-oc` applied MachineConfig to worker nodes
3. **Tested on EC2 VMs** (m6a.4xlarge, g6.4xlarge, g6e.4xlarge):
   - CPU flags: `vmx/svm = 0` — nested virtualization not exposed
   - `/dev/kvm`: absent
   - Pod error: `qemu-kvm: Could not access KVM kernel module: No such file or directory`
4. **Tested on EC2 bare metal** (m5.metal):
   - CPU flags: `vmx = 192` (Intel Xeon Platinum 8259CL, 96 vCPU)
   - `/dev/kvm`: present (`crw-rw-rw-. 1 root kvm 10, 232`)
   - Kata pod: **Running** — isolated kernel, ~15s boot

### Alternatives Evaluated

| Option | Works on EC2 VMs | Supported by Red Hat | Notes |
|---|---|---|---|
| **Kata + bare metal** | N/A (bare metal) | Yes | Requires `*.metal` instances (~$4.6/h) |
| **Kata + peer-pods** | Yes | Operator 1.5+ only | Creates EC2 VM per pod via API. Our operator is 1.3. |
| **gVisor (runsc)** | Yes | No | User-space kernel, no `/dev/kvm` needed. Not in OpenShift. |
| **Agent Sandbox CRD** | Yes (with gVisor) | Community (k8s-sigs) | v0.2.1, supports gVisor + Kata backends |
| **PSS + SELinux + NetworkPolicy** | Yes | Yes | Already deployed. Shared kernel. |

## Decision

Use **bare metal EC2 instances** (`m5.metal`) as Kata worker nodes for agent workloads. Provision via MachineSet.

### Infrastructure Changes

- **MachineSet**: `ocp-dgpmb-kata-baremetal-us-east-2c` (m5.metal, 1 replica)
- **Node labels**: `node-role.kubernetes.io/worker`, `node-role.kubernetes.io/kata-baremetal`
- **MCP**: `kata-oc` automatically applies Kata runtime via MachineConfig
- **Claude Code Deployment**: `runtimeClassName: kata`, `nodeSelector: m5.metal`

### Cost Impact

| Instance | vCPU | RAM | Price/h | Role |
|---|---|---|---|---|
| m5.metal | 96 | 384 GB | ~$4.61/h | Kata workers (agent pods) |
| g6e.4xlarge | 1 GPU | 64 GB | ~$1.86/h | vLLM inference |
| m6a.4xlarge | 16 | 64 GB | ~$0.69/h | General workers (no Kata) |

A single m5.metal can host 40-80+ Claude Code Kata pods concurrently (each ~1 CPU, 2 GB RAM).

### Token Limit Fix

`CLAUDE_CODE_MAX_OUTPUT_TOKENS` reduced from 16384 to **8192**. Claude Code's system prompt consumes ~16K tokens; with 8192 output tokens, total = ~24K — safely under Qwen 2.5 14B's 32768 context window.

## Known Issues

- **Sandboxed Containers monitor pods** crash with `write to /proc/self/attr/keycreate: Invalid argument` (SELinux incompatibility between operator 1.3.3/RHEL8 images and OCP 4.20/RHEL9 kernel). Does not affect Kata runtime functionality.
- **c5.metal**: `InsufficientInstanceCapacity` in us-east-2a and us-east-2b. m5.metal available in us-east-2c.

## Consequences

### Positive
- Agent pods run in fully isolated MicroVMs with dedicated kernel
- Compatible with Kubernetes API — only `runtimeClassName: kata` needed
- Single m5.metal node supports dozens of concurrent agents
- Defense-in-depth: Kata + PSS + SELinux + NetworkPolicy

### Negative
- Bare metal cost (~$4.6/h vs $0.69/h for VMs)
- m5.metal is Intel Xeon (older gen) — no cost-optimized bare metal for Graviton/AMD
- Bare metal availability varies by AZ — capacity planning required

### Future
- Upgrade to Sandboxed Containers Operator 1.5+ for **peer-pods** (no bare metal needed)
- Evaluate **Agent Sandbox CRD** (k8s-sigs) with **gVisor** as lighter alternative
- Consider `m5d.metal` or `m6i.metal` for newer hardware
