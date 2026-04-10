# Infrastructure Requirements: AgentOps Platform

**Status:** Validated (Sprint 1)
**Data:** 2026-04-08
**Relacionado:** [Arquitetura](ARCHITECTURE.md) | [ADRs](adrs/) | [Plan](PLAN.md)

---

## TL;DR

Para rodar Claude Code + vLLM (Qwen 2.5 14B) no OpenShift de forma confortavel:

- **1x GPU node** com NVIDIA L40S (48GB VRAM) ou superior
- **2-3x worker nodes** com 16GB+ RAM cada
- **OpenShift 4.16+** com GPU Operator
- **~100GB storage** (PVCs + registry)
- **Acesso admin** ao cluster

---

## 1. Cluster OpenShift

| Requisito | Minimo | Recomendado | Nota |
|---|---|---|---|
| Versao OpenShift | 4.16 | 4.18+ | APIs estaveis, Pod Security Standards, MachineSet |
| Control plane | 3x nodes (managed) | 3x nodes | Gerenciado pelo cloud provider (ROSA, ARO, etc.) |
| Workers gerais | 2x (4 vCPU, 16GB RAM) | 3x (8 vCPU, 32GB RAM) | Pods de agente (sem Kata), Coder, observabilidade, build pods |
| GPU worker | 1x (ver secao GPU) | 1x dedicado com taint | Node exclusivo pra inferencia |
| Bare metal worker | 1x m5.metal (se usar Kata) | 1x m5.metal | Kata requer /dev/kvm — EC2 VMs nao suportam (ADR-017) |
| Acesso | `cluster-admin` | `cluster-admin` | Necessario pra instalar operators, criar MachineSet, configurar RBAC |

### Workers gerais — sizing

Os workers gerais hospedam tudo exceto o vLLM:

| Workload | CPU request | Memory request | CPU limit | Memory limit |
|---|---|---|---|---|
| Claude Code pod (xN) | 100m | 256Mi | 1 | 2Gi |
| Claude Code build pod | 500m | 1Gi | 2 | 4Gi |
| Coder control plane | 500m | 512Mi | 2 | 2Gi |
| PostgreSQL (Coder) | 500m | 1Gi | 2 | 4Gi |
| MLflow | 250m | 512Mi | 2 | 2Gi |
| TrustyAI Guardrails | 500m | 512Mi | 2 | 4Gi |
| MCP Gateway | 200m | 256Mi | 1 | 2Gi |
| **Total (stack completa)** | **~3 vCPU** | **~4.3Gi** | **~13 vCPU** | **~23Gi** |

> Com 2x workers de 8 vCPU / 32GB RAM ha margem confortavel pra escalar agentes.

### Escala de agentes

Claude Code standalone roda como um Deployment — cada replica eh um agente independente. Inclui tanto pods standalone quanto Coder workspaces (cada workspace tambem tem seu Claude Code).

Cada agente consome ~100m CPU / 256Mi (idle) a ~1 vCPU / 2Gi (executando). Estimativa:

| Agentes simultaneos | Workers gerais recomendados | Comando |
|---|---|---|
| 1-5 | 2x (8 vCPU, 32GB) | `oc scale deployment/claude-code-standalone --replicas=5` |
| 5-15 | 3x (8 vCPU, 32GB) | |
| 15-25 | 4x (16 vCPU, 64GB) ou autoscaler | |

---

## 2. GPU — Node de Inferencia

O modelo (Qwen 2.5 14B Instruct FP8-dynamic) usa ~15GB de VRAM. O restante vai pra KV cache (context window).

### Tiers de GPU

| Tier | GPU | VRAM | Instance (AWS) | `max_model_len` | `max_output_tokens` | CUDA graphs | Custo/h (on-demand) | Veredicto |
|---|---|---|---|---|---|---|---|---|
| **Minimo** | L4 | 24GB | g6.4xlarge | 24,576 | 2,048 | Nao (`enforce-eager`) | $1.32 | Funciona, mas apertado. Output limitado a 2K tokens. |
| **Confortavel** | L40S | 48GB | g6e.4xlarge | 32,768 | 8,192 | Sim | $1.86 | Context completo do modelo. Recomendado. System prompt ~16K + 8K output = 24K < 32K. |
| **Premium** | A100 40GB | 40GB | p4d.xlarge* | 32,768 | 8,192 | Sim | $3.09+ | Overkill pra 14B. Justifica so com modelo maior. |
| **Overkill** | A100 80GB / H100 | 80GB | p4d / p5 | 32,768+ | 8,192+ | Sim | $5.12+ | So faz sentido com Qwen 72B ou multi-GPU. |

> **Recomendacao: NVIDIA L40S (48GB)** — melhor custo-beneficio pra Qwen 2.5 14B.

### Spec do GPU node

| Recurso | Valor |
|---|---|
| Instance type (AWS) | `g6e.4xlarge` |
| vCPU | 16 |
| RAM | 128GB |
| GPU | 1x NVIDIA L40S (48GB VRAM) |
| Disk root | 1500GB gp3 (imagem vLLM ~22GB + sistema) |
| Taint | `nvidia.com/gpu=true:NoSchedule` |
| Labels | `node-role.kubernetes.io/gpu`, `nvidia.com/gpu.product: NVIDIA-L40S` |

### Por que 1500GB de disco root?

- Imagem vLLM: ~22GB
- Imagem base OpenShift + overlays: ~10GB
- Espaco pra containers efemeros, logs, tmp: ~20GB
- Margem: o resto eh buffer pra pulls, OCI cache, etc.

> Em cloud, disco eh barato. Colocar pouco disco num node GPU causa eviction por `DiskPressure`.

---

## 3. Storage (PVCs)

| PVC | Tamanho | StorageClass | AccessMode | Namespace | Proposito |
|---|---|---|---|---|---|
| `qwen25-14b-model-cache` | 30Gi | gp3-csi | ReadWriteOnce | inference | Modelo FP8 (~7GB) + cache HF (~9GB) + torch compile cache |
| PostgreSQL (Coder) | 10Gi | gp3-csi | ReadWriteOnce | coder | Estado do Coder |
| MLflow artifacts | 20Gi | gp3-csi | ReadWriteOnce | observability | Traces e artifacts |
| **Total PVC** | **~60Gi** | | | | |

### Internal Image Registry

| Recurso | Tamanho estimado |
|---|---|
| `claude-code-agent:latest` | ~1.5GB |
| Overhead registry | ~5GB |
| **Total registry** | **~10GB** |

> O registry usa storage do cluster (tipicamente S3 em cloud). Confirme que ha quota suficiente.

---

## 4. Operators Obrigatorios

| Operator | Canal | Necessidade | Quando instalar |
|---|---|---|---|
| **NVIDIA GPU Operator** | stable | GPU driver + device plugin nos nodes | Antes de qualquer workload GPU |
| **Node Feature Discovery** | stable | Detecta GPUs e features de hardware | Pre-requisito do GPU Operator |
| **cert-manager** | stable-v1 | TLS para routes internas | Sprint 1 |

### Operators Opcionais (por fase)

| Operator | Fase | Necessidade |
|---|---|---|
| OpenShift Sandboxed Containers (Kata) | 1 (validado) | Isolamento microVM por agente. **Requer bare metal** (ADR-017). Bug SELinux em OCP 4.20 (ADR-018). |
| Red Hat OpenShift AI (RHOAI) | 2 | TrustyAI Guardrails |
| OpenShift Serverless | 2 | KServe (se usar no futuro) |
| OpenShift Pipelines (Tekton) | 5 | CI/CD safety scans |

---

## 5. Rede

### Conectividade de saida (egress)

| Source | Destino | Porta | Quando |
|---|---|---|---|
| GPU node | `huggingface.co`, `cdn-lfs.huggingface.co` | 443 | Download do modelo (primeiro boot ou PVC vazio) |
| GPU node | `ghcr.io`, `docker.io` | 443 | Pull da imagem vLLM |
| Build pods | `registry.access.redhat.com` | 443 | Pull da base image UBI |
| Build pods | `registry.npmjs.org` | 443 | Install Claude Code CLI |
| Agent pods | `github.com`, `api.github.com` | 443 | Git operations (se habilitado) |

### Conectividade interna (cluster)

| Source | Destination | Porta | Protocolo |
|---|---|---|---|
| `agent-sandboxes` → `inference` | vLLM | 8080 | HTTP (Anthropic Messages API) |
| `agent-sandboxes` → `openshift-dns` | CoreDNS | 53, 5353 | UDP/TCP |
| `agent-sandboxes` → API server | K8s API | 443, 6443 | TCP |
| `inference` → `openshift-dns` | CoreDNS | 53, 5353 | UDP/TCP |

> **Atencao:** OpenShift CoreDNS escuta na porta **5353** (nao 53 padrao). OVN-Kubernetes avalia NetworkPolicy pos-DNAT. As regras de egress DNS precisam incluir ambas as portas. (ADR-013)

---

## 6. Checklist Pre-Deploy

```
[ ] OpenShift 4.16+ com acesso cluster-admin
[ ] GPU Operator + NFD instalados e funcionais
[ ] Pelo menos 1x GPU node provisionado (L40S recomendado)
    [ ] nvidia-smi funciona dentro do node
    [ ] GPU allocatable = 1 no node status
[ ] StorageClass com provisioner funcional (gp3-csi, gp2, etc.)
[ ] Pull secrets configurados:
    [ ] registry.access.redhat.com (UBI base image)
    [ ] docker.io / ghcr.io (vLLM image)
    [ ] quay.io (operators)
[ ] Egress permitido para:
    [ ] huggingface.co (download modelo)
    [ ] registry.npmjs.org (install Claude Code)
    [ ] registry.access.redhat.com (build image)
[ ] Image registry interno funcional (oc registry info)
[ ] Workers gerais com pelo menos 4Gi livres para build pods
[ ] Bare metal node (se planeja usar Kata Containers)
    [ ] Instance type *.metal (m5.metal, c5.metal)
    [ ] /dev/kvm presente no node
    [ ] VMX/SVM CPU flags > 0
    [ ] KataConfig CR criado e MCP kata-oc updated
    [ ] RuntimeClass 'kata' existe
```

> **Nota Kata (ADR-017):** EC2 VMs regulares (g6, m6a, c5, etc.) **nao suportam** Kata porque nao expoe `/dev/kvm`. Somente instances `*.metal` funcionam. Se bare metal nao estiver disponivel na AZ desejada, considere outra AZ ou instance family. `c5.metal` frequentemente tem `InsufficientInstanceCapacity`; `m5.metal` eh mais confiavel.

---

## 7. Custo Estimado (AWS, on-demand)

| Componente | Instance | Qtd | Custo/h | Custo/mes (24x7) |
|---|---|---|---|---|
| Control plane | Managed (ROSA/OCP) | 3 | incluso* | ~$500* |
| Workers gerais | m6i.2xlarge (8 vCPU, 32GB) | 2 | $0.384 | ~$553 |
| GPU worker | g6e.4xlarge (16 vCPU, 128GB, 1x L40S) | 1 | $1.86 | ~$1,339 |
| Bare metal (Kata) | m5.metal (96 vCPU, 384GB) | 1 | $4.61 | ~$3,319 |
| Storage (EBS gp3) | ~200GB total | — | — | ~$16 |
| **Total estimado (com Kata)** | | | | **~$5,700/mes** |
| **Total estimado (sem Kata)** | | | | **~$2,400/mes** |

> *Control plane gerenciado varia por provider. Com spot/reserved instances, GPU cai ~60%.

### Otimizacao de custo

| Estrategia | Economia | Trade-off |
|---|---|---|
| Spot instance pro GPU node | ~60-70% | Pode ser interrompido (modelo re-download do PVC em ~2 min) |
| Reserved instance (1y) | ~30-40% | Commitment |
| Desligar GPU node fora do horario | ~66% | MachineSet `replicas: 0` fora do horario comercial |
| L4 em vez de L40S | ~30% | Context limitado a 24K, output a 2K tokens |

---

## 8. Escala Futura

### Modelo maior (Qwen 2.5 32B ou 72B)

| Modelo | VRAM necessaria | GPU minima | Instance |
|---|---|---|---|
| Qwen 2.5 14B FP8 | ~15GB | L40S (48GB) | g6e.4xlarge |
| Qwen 2.5 32B FP8 | ~32GB | A100 40GB | p4d.xlarge |
| Qwen 2.5 72B FP8 | ~72GB | 2x A100 40GB ou 1x A100 80GB | p4d.24xlarge |

### Multi-agente (10+ agentes simultaneos)

| Componente | Ajuste |
|---|---|
| Workers gerais | Escalar pra 4-6 nodes (ou cluster autoscaler) |
| vLLM | Adicionar `--max-num-seqs` pra limitar concorrencia; ou 2x GPU pra tensor parallelism |
| Coder | HA deployment (2+ replicas) |
| Storage | Migrar model cache pra FSx/EFS (`ReadWriteMany`) se multi-GPU |

---

## 9. Compatibilidade Cloud

| Provider | GPU Instance | StorageClass | Registry | Notas |
|---|---|---|---|---|
| **AWS (ROSA/OCP)** | g6e.4xlarge (L40S) | gp3-csi | S3-backed | Validado neste PoC |
| **Azure (ARO)** | NC16as_T4_v3 (T4) ou NCv3 (V100) | managed-csi | Azure CR | T4 = tier minimo, V100 = confortavel |
| **GCP** | a2-highgpu-1g (A100) ou g2-standard-16 (L4) | pd-ssd | GCR/AR | L4 disponivel via G2 series |
| **Bare metal** | Qualquer NVIDIA ≥24GB | Local storage | Quay/Harbor | Precisa de provisioner (LVM, Ceph) |
| **IBM Cloud (ROKS)** | Nao tem GPU nativo | — | — | Nao recomendado pra este workload |

---

## 10. Resumo Visual

```
┌─────────────────────────────────────────────────────────────────┐
│                    OpenShift 4.16+ Cluster                      │
│                                                                 │
│  ┌──────────────────────┐   ┌────────────────────────────────┐  │
│  │   Workers Gerais     │   │      GPU Worker (dedicado)     │  │
│  │   2-3x m6i.2xlarge   │   │      1x g6e.4xlarge           │  │
│  │   8 vCPU, 32GB RAM   │   │      16 vCPU, 128GB RAM       │  │
│  │                      │   │      1x NVIDIA L40S (48GB)     │  │
│  │  ┌────────────────┐  │   │                                │  │
│  │  │ Claude Code    │  │   │  ┌──────────────────────────┐  │  │
│  │  │ pods (agents)  │──│───│─>│ vLLM + Qwen 2.5 14B FP8 │  │  │
│  │  └────────────────┘  │   │  │ max_model_len=32768      │  │  │
│  │  ┌────────────────┐  │   │  │ gpu-mem-util=0.90        │  │  │
│  │  │ Coder, MLflow,  │  │   │  └──────────────────────────┘  │  │
│  │  │ Guardrails,    │  │   │  ┌──────────────────────────┐  │  │
│  │  │ MCP Gateway    │  │   │  │ PVC 30Gi (model cache)   │  │  │
│  │  └────────────────┘  │   │  └──────────────────────────┘  │  │
│  └──────────────────────┘   └────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────┐                                       │
│  │  Bare Metal (Kata)   │   Operators: GPU, NFD, cert-manager,  │
│  │  1x m5.metal         │             Sandboxed Containers      │
│  │  96 vCPU, 384GB RAM  │                                       │
│  │  /dev/kvm → QEMU     │   Storage: gp3-csi (~100Gi PVCs)     │
│  │                      │                                       │
│  │  ┌────────────────┐  │   Custo (com Kata):                   │
│  │  │ Claude Code    │  │     ~$5,700/mes (on-demand)           │
│  │  │ Kata MicroVM   │  │     ~$2,500/mes (optimizado)          │
│  │  └────────────────┘  │                                       │
│  └──────────────────────┘   Custo (sem Kata):                   │
│                               ~$2,400/mes (on-demand)           │
│                               ~$1,000/mes (optimizado)          │
└─────────────────────────────────────────────────────────────────┘
```
