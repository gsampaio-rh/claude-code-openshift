# Plan: AgentOps Platform — Sprints

**Status:** Draft
**Data:** 2026-04-08
**Relacionado:** [PRD](PRD.md) | [Arquitetura](ARCHITECTURE.md) | [ADRs](adrs/)

---

## Visao geral

5 sprints de 1 semana cobrindo Fases 0-8 do PRD. Fase 9 (Dev Spaces) eh pos-PoC.

```
Sprint 1 ████░░░░░░░░░░░░░░░░ Infra + vLLM + Claude Code standalone
Sprint 2 ░░░░████░░░░░░░░░░░░ Observability + Safety + Coder
Sprint 3 ░░░░░░░░████░░░░░░░░ Kata + Kagenti
Sprint 4 ░░░░░░░░░░░░████░░░░ MCP Gateway
Sprint 5 ░░░░░░░░░░░░░░░░████ CI/CD + Integracao end-to-end
```

**Convencoes:**
- `[ ]` = pendente | `[x]` = feito | `[!]` = bloqueado
- **Gate** = criterio que precisa passar pra ir pro proximo sprint
- **Artefato** = arquivo/manifesto que precisa ser criado no repositorio

---

## Sprint 1 — Infra base + Inferencia + Agente standalone (Semana 1)

> **Meta:** Cluster validado, operators instalados, modelo Qwen rodando, Claude Code conversando com o modelo.
>
> **Fases PRD:** 0 + 1 + 1a

### 1.1 Pre-flight check (Fase 0)

- [x] Executar `infra/cluster/scripts/00-preflight-check.sh`
- [x] Validar versao OpenShift (4.16+) — OCP 4.20.17 confirmado
- [x] Validar acesso admin (`oc whoami`, `oc auth can-i '*' '*'`)
- [x] Validar GPU disponivel — 1x NVIDIA L4 (24GB) confirmado
- [x] Verificar operators instalados (GPU, NFD, RHOAI, Serverless, Pipelines, cert-manager)
- [x] Verificar workloads existentes que consomem GPU
- [x] Verificar pull secrets (registry.redhat.io, quay.io)
- [x] Verificar DataScienceCluster e KServe CRDs
- [x] Validar suporte a nested virt / bare metal (requisito Kata) — EC2 VMs nao suportam (ADR-017), bare metal m5.metal provisionado

### 1.2 Operators base (Fase 0)

- [x] NVIDIA GPU Operator — ja instalado no sandbox
- [x] Node Feature Discovery Operator — ja instalado
- [x] cert-manager Operator — ja instalado
- [x] Instalar OpenShift Sandboxed Containers Operator (Kata) — v1.3.3, canal stable-1.3
- [x] Criar KataConfig CR para habilitar runtime nos nodes — MCP kata-oc atualizado

**Artefatos:**

```
infra/cluster/
├── scripts/
│   ├── config.sh                    # Variaveis de namespace
│   ├── 00-preflight-check.sh        # Investigacao completa do ambiente
│   ├── 01-setup-cluster.sh          # Namespaces, RBAC, quotas, network policies
│   ├── 02-install-operators.sh      # NFD, GPU, cert-manager
│   ├── 03-install-kata.sh           # Sandboxed Containers Operator + KataConfig
│   └── 04-validate-kata.sh          # Kata end-to-end validation (bare metal, /dev/kvm, test pod)
├── machinesets/                     # MachineSet manifests (GPU, bare metal)
│   ├── gpu-l40s.yaml                # g6e.4xlarge (NVIDIA L40S)
│   └── kata-baremetal.json          # m5.metal (bare metal for Kata)
├── namespaces/                      # Manifests de namespace, RBAC, quotas
├── operators/                       # Subscriptions de operators
│   ├── gpu-operator.yaml
│   ├── nfd-operator.yaml
│   ├── sandboxed-containers.yaml
│   ├── kataconfig.yaml
│   └── cert-manager.yaml
```

### 1.3 Namespaces e RBAC (Fase 0)

- [x] Criar namespaces: `coder`, `agentops`, `agent-sandboxes`, `inference`, `mcp-gateway`, `observability`, `cicd`
- [x] Configurar NetworkPolicy base entre namespaces (corrigida em runtime — ADR-013)
- [x] Criar ResourceQuota por namespace
- [x] Configurar RBAC basico (roles pra platform engineer vs dev)

**Artefatos:**

```
infra/cluster/
├── namespaces/
│   ├── namespaces.yaml              # Todos os namespaces
│   ├── network-policies.yaml        # Regras de isolamento
│   ├── resource-quotas.yaml         # Quotas por namespace
│   └── rbac.yaml                    # Roles e RoleBindings
```

### 1.4 Inferencia local com vLLM (Fase 1)

- [x] Deploy upstream vLLM v0.19.0 como Deployment+Service no namespace `inference` (ADR-011, ADR-012)
- [x] Configurar modelo Qwen 2.5 14B Instruct FP8-dynamic no L4 24GB
- [x] Criar Service ClusterIP (nao expor externamente)
- [x] Validar `/v1/models` — modelo listado como `qwen25-14b`
- [x] Validar `/v1/chat/completions` (OpenAI API) — resposta funcional
- [x] Validar `/v1/messages` (Anthropic Messages API) — resposta funcional com codigo Python
- [x] Executar script de validacao completo: `infra/vllm/scripts/02-validate-model.sh` — 21 checks pass, 1 warning
- [x] Testar latencia com prompt simples (target: < 5s) — 2.1s (math), 7.2s (fibonacci), 26.3s (LRU cache) no L40S

**Decisoes tomadas:**
- RHAIIS (Red Hat AI Inference Server) **nao tem** a Anthropic Messages API (`/v1/messages`) — ver ADR-011
- KServe `ServingRuntime`+`InferenceService` substituido por plain `Deployment`+`Service` — ver ADR-012
- Cache dirs (`HF_HOME`, `XDG_CACHE_HOME`, `HOME`) redirecionados para volumes writables (OpenShift random UID)
- `startupProbe` com 10 min de tolerancia para download do modelo
- `--max-model-len=24576` (Sprint 1, L4): system prompt ~12K tokens; 16K estourava com 4096 output; 32K excedia KV cache do L4. Escalado pra 32768 com L40S (ADR-016)
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS=2048` (Sprint 1, L4): complementava ajuste de context. Escalado pra 16384 com L40S (ADR-016)

**Artefatos:**

```
infra/vllm/
├── manifests/
│   ├── pvc.yaml                     # PVC 30Gi gp3-csi para model cache (ADR-014)
│   ├── deployment.yaml              # Deployment com upstream vLLM v0.19.0
│   ├── service.yaml                 # ClusterIP Service porta 8080
│   └── kustomization.yaml           # pvc + deployment + service
├── scripts/
│   ├── config.sh                    # Variaveis (imagem, modelo, namespace)
│   ├── 00-setup-namespace.sh        # Namespace + quotas
│   ├── 01-deploy-model.sh           # Apply + wait rollout
│   ├── 02-validate-model.sh         # Validacao completa (health, APIs, security, coding)
│   ├── 99-verify.sh                 # Alias para 02-validate-model.sh
│   └── 99-cleanup.sh               # Cleanup
```

### 1.5 Claude Code standalone (Fase 1a)

- [x] Criar ConfigMap `claude-code-config` no namespace `agent-sandboxes` com env vars do agente
- [x] Build e push da imagem custom (UBI9 nodejs-22 + Claude Code v2.1.96) via `oc start-build` (internal registry)
- [x] Deploy pod standalone com imagem custom
- [x] Configurar `ANTHROPIC_BASE_URL` apontando direto pro vLLM (sem Guardrails por enquanto)
- [x] Validar: `oc exec claude-code-standalone -- claude -p "What is 2+2?"` → `4` (~6s)
- [x] Testar prompts de coding progressivos:
  - [x] Funcao simples (fibonacci) — codigo correto (~9s)
  - [x] Estrutura de dados (LRU cache com type hints) — doubly-linked list correto (~101s)
- [x] Medir latencia end-to-end: ~6s pra prompt simples, ~9s pra funcao, ~101s pra classe complexa
- [x] **Go/no-go**: Qwen 14B produz codigo funcional ✓ — prosseguir pro Sprint 2

**Problemas encontrados e resolvidos:**
- Dockerfile PATH errado (`/home/default/.local/bin` → `/opt/app-root/src/.local/bin`): UBI nodejs-22 usa `HOME=/opt/app-root/src`
- Build pod OOM (exit 137 com 1Gi): Claude Code install precisa de 4Gi
- NetworkPolicy bloqueava DNS e conectividade agent→vLLM: ADR-013
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS=4096` estourava context window de 16K: reduzido pra 2048 + context pra 24K
- ResourceQuota exigia limits em build pods: patch no BuildConfig
- CPU saturada no node (97%): pod Claude Code reduzido pra 100m request

**Artefatos:**

```
infra/claude-code/
├── manifests/
│   ├── configmap.yaml               # ConfigMap claude-code-config
│   └── standalone-pod.yaml          # Deployment (runtimeClassName: kata, nodeSelector: m5.metal)
├── scripts/                         # build, deploy, verify, cleanup
├── entrypoint.sh                    # Startup banner + MLflow autolog (ADR-015)
├── set-trace-tags.py                # Stop hook for per-trace metadata (disabled — ADR-020)
├── claude-logged                    # Wrapper: claude -p --verbose --output-format stream-json
└── Dockerfile                       # UBI9 nodejs-22 + Claude Code CLI + MLflow + entrypoint
```

**DECISAO: Go/No-Go do modelo**

Este eh o checkpoint mais importante do PoC. Se Claude Code + Qwen 2.5 14B nao produz respostas uteis pra coding, nao faz sentido montar Coder, Kata, MCP Gateway em cima. Opcoes:

| Resultado | Acao |
|---|---|
| Qwen 14B funciona bem | Continuar pro Sprint 2 |
| Qwen 14B funciona parcialmente | Testar quantizacao diferente ou Qwen 32B |
| Qwen 14B nao funciona | Avaliar modelo alternativo ou usar API cloud como fallback |

### Gate do Sprint 1

| # | Criterio | Status | Nota |
|---|---|---|---|
| G1.1 | Todos os operators em status `Succeeded` | ✅ | GPU, NFD, cert-manager, RHOAI, Serverless, Pipelines |
| G1.2 | KataConfig status `ready` nos nodes | ✅ | Kata installed, m5.metal bare metal node provisionado, E2E OK (ADR-017). osc-monitor bug (ADR-018). |
| G1.3 | vLLM respondendo em `/v1/messages` e `/v1/chat/completions` | ✅ | upstream vLLM v0.19.0 (ADR-011, ADR-012) |
| G1.4 | Claude Code standalone conversa com vLLM (AC-0) | ✅ | fibonacci, LRU cache, math — todos funcionais |
| G1.5 | Latencia < 5s para prompt simples | ✅ | L40S: 2.1s (math), 7.2s (function), 26.3s (class). L4 anterior: ~6s, ~9s, ~101s |
| G1.6 | Go/no-go do modelo: codigo gerado eh funcional | ✅ GO | Qwen 14B produz codigo correto e com type hints |
| G1.7 | Namespaces e NetworkPolicies criadas | ✅ | Corrigido em Sprint 1 (ADR-013) |

---

## Sprint 2 — Observability + Safety + CDE (Semana 2)

> **Meta:** Traces de tudo no MLflow. Guardrails interceptando requests. Coder rodando com workspaces funcionais.
>
> **Fases PRD:** 7 + 2 + 3

### 2.0 Hardening Sprint 1 (carry-over)

- [x] Adicionar egress NetworkPolicy para namespace `inference` (DNS + HuggingFace 443 only)
- [x] Migrar `model-cache` de `emptyDir` para `PVC` 30Gi gp3-csi (modelo 16GB persistido, restart sem re-download)
- [x] Remover NetworkPolicies temporarias (`allow-claude-egress-temp`, `allow-builds-egress`)
- [x] Rebuild imagem Claude Code com PATH corrigido (`/opt/app-root/src/.local/bin`)

### 2.0a GPU Scaling (ADR-016)

- [x] Criar MachineSet `gpu-l40s-us-east-2b` (g6e.4xlarge, 1x NVIDIA L40S 48GB)
- [x] Aguardar node provisionar + GPU Operator instalar driver (~10 min)
- [x] Reconfigurar vLLM: `max_model_len=32768`, remover `--enforce-eager`, `gpu-memory-utilization=0.90`
- [x] Corrigir `max_model_len`: Qwen 2.5 14B tem `max_position_embeddings=32768` (nao 131072, que eh so pra modelos maiores com YaRN)
- [x] Mudar Deployment strategy de `RollingUpdate` para `Recreate` (PVC RWO nao suporta multi-attach cross-node)
- [x] Aumentar `inference-quota`: memory 64Gi→128Gi, cpu 16→32
- [x] Migrar vLLM pro node L40S via `nodeSelector` + `tolerations`
- [x] Validar rollout: pod 1/1 Running no node L40S
- [x] Subir `CLAUDE_CODE_MAX_OUTPUT_TOKENS` de 2048 para 16384
- [x] E2E test: Claude Code → vLLM (L40S) — input 22K tokens, output 594 tokens, ~23s

**Problemas encontrados e resolvidos:**
- `max_model_len=131072` crashava: Qwen 2.5 14B `max_position_embeddings=32768`. Corrigido pra 32768.
- PVC Multi-Attach error: EBS RWO nao suporta attach em 2 nodes simultaneamente. Corrigido com strategy `Recreate`.
- ResourceQuota bloqueava pod novo (old 24Gi + new 48Gi > 64Gi limit). Aumentada pra 128Gi.

### 2.0b Kata Containers — Bare Metal (ADR-017, ADR-018)

- [x] Validar nested virt nos nodes existentes: EC2 VMs (g6, g6e, m6a) nao expoe `/dev/kvm`
- [x] Testar Kata pod em VM worker: falha com `qemu-kvm: Could not access KVM kernel module`
- [x] Pesquisar alternativas: peer-pods (operator 1.5+ requerido), gVisor (nao suportado em OpenShift)
- [x] Decidir provisionar bare metal: `m5.metal` (c5.metal falhou por `InsufficientInstanceCapacity` em us-east-2a/b)
- [x] Criar MachineSet `kata-baremetal-us-east-2c` (m5.metal, 96 vCPU, 384GB RAM)
- [x] Aguardar node provisionar (~10 min) e juntar ao cluster
- [x] Validar `/dev/kvm` presente e flags VMX no bare metal
- [x] Instalar Sandboxed Containers Operator v1.3.3 (stable-1.3)
- [x] Criar KataConfig CR → MCP `kata-oc` atualiza nodes
- [x] Validar RuntimeClass `kata` criado
- [x] Deployar test pod com `runtimeClassName: kata` + `nodeSelector: m5.metal` — sucesso
- [x] Deployar Claude Code com Kata no bare metal
- [x] E2E test: Claude Code (Kata MicroVM) → vLLM → codigo Python gerado
- [x] Corrigir `CLAUDE_CODE_MAX_OUTPUT_TOKENS`: 16384 estourava context (16K system + 16384 = 32769 > 32768). Reduzido pra 8192.
- [x] Escalar down MachineSet `m6a.4xlarge` (nao usado, custo)
- [x] Atualizar Deployment `claude-code-standalone` com `runtimeClassName: kata` + `nodeSelector: m5.metal`
- [x] Registrar ADR-017 (Kata requer bare metal) e ADR-018 (SELinux bug osc-monitor)
- [x] Criar scripts: `03-install-kata.sh`, `04-validate-kata.sh`
- [x] Salvar MachineSet manifest: `infra/cluster/machinesets/kata-baremetal.json`

**Problemas encontrados e resolvidos:**
- EC2 VMs nao tem `/dev/kvm` — Kata QEMU requer bare metal. Documentado em ADR-017.
- `c5.metal` falhou em us-east-2a e us-east-2b: `InsufficientInstanceCapacity`. Switch pra `m5.metal` em us-east-2c.
- `osc-monitor` DaemonSet crashloop: SELinux incompatibilidade RHEL 8 images vs RHEL 9 kernel. ADR-018.
- `CLAUDE_CODE_MAX_OUTPUT_TOKENS=16384` estourava context por 1 token. Corrigido pra 8192.
- Pod `qwen25-14b` em `UnexpectedAdmissionError`: residuo de rollout L4→L40S. Deletado manualmente.

### 2.1 Observabilidade (Fase 7)

- [x] Deploy OTEL Collector no namespace `observability` — otel-collector-contrib v0.120.0, OTLP receivers, health_check extension
- [x] Configurar receiver OTLP (gRPC :4317, HTTP :4318)
- [x] Deploy MLflow Tracking Server com storage (PV ou S3) — atualizado pra MLflow v3.10.1, sqlite + PVC 10Gi
- [x] Configurar Claude Code: `OTEL_EXPORTER_OTLP_ENDPOINT` — ConfigMap atualizado, NetworkPolicy criada
- [x] Criar dashboards basicos: Grafana OSS 11.5.2 com dashboard AgentOps (spans/min, latency p50/p95/p99, active services, collector health)
- [x] Configurar spanmetrics connector → prometheus exporter (:8889) → Prometheus dedicado no namespace
- [x] Expor MLflow UI via Route TLS edge — `https://mlflow-tracking-observability.apps.<cluster>`
- [x] Expor Grafana via Route TLS edge — `https://grafana-observability.apps.<cluster>`
- [x] ADR-019: Observability stack decisions (MLflow native + OTEL for metrics)
- [x] Configurar `mlflow autolog claude` — Dockerfile com `pip install mlflow>=3.10`, entrypoint.sh chama `mlflow autolog claude`, ConfigMap com `MLFLOW_TRACKING_URI` + `MLFLOW_EXPERIMENT_NAME`
- [x] Remover `otlphttp/mlflow` do OTEL Collector — redundante com integracao nativa. OTEL fica apenas para Grafana metrics via spanmetrics.
- [x] Desabilitar OTEL Collector, Prometheus e Grafana — MLflow autolog eh a unica observabilidade necessaria pro PoC. Manifests mantidos em `observability/{otel,prometheus,grafana}/` para re-ativacao futura. Scripts e docs atualizados para MLflow-only.
- [x] Enriquecer metadata dos traces — implementado e validado E2E, depois **desabilitado** (complexidade desproporcional para single-agent). Experiment-level tags permanecem ativos. Per-trace hook (`set-trace-tags.py`) mantido no repo para re-ativacao em multi-agent. Ver ADR-020.

**Problemas encontrados e resolvidos:**
- OTEL Collector crashloop: `health_check` extension nao estava configurada, readiness probe em `:13133` falhava. Corrigido adicionando `extensions.health_check`.
- MLflow container nao tem `curl`: verify script adaptado pra usar `python urllib` nativo.
- MLflow v3.10.1 OOMKilled com 1Gi: v3 spawna huey workers pra scoring jobs. Aumentado limite pra 2Gi.
- MLflow v3 `--allowed-hosts`: security middleware rejeita requests com Host header desconhecido. Adicionado hostname do Route e service interno.
- OTEL `spanmetrics` connector: `service.name` e `span.kind` sao dimensoes built-in, nao podem ser listadas como custom dimensions.
- NetworkPolicy: trafego intra-namespace bloqueado. Adicionado `podSelector: {}` ingress rule pra Grafana acessar OTEL metrics.
- MLflow v3 CORS: `Blocked cross-origin request` no browser. Adicionado `--cors-allowed-origins` com hostname do Route.
- MLflow `--allowed-hosts`: deve incluir `localhost`, `localhost:5000`, service name com e sem porta, e hostname do Route. Security middleware faz exact match no Host header.
- `mlflow autolog claude` (MLflow >= 3.4): integracao nativa Claude Code → MLflow com tool calls, tokens, conversas. Substitui `otlphttp/mlflow` do OTEL Collector (que produzia spans genericos). Ref: https://mlflow.org/docs/latest/genai/tracing/integrations/listing/claude_code/
- OTEL `otlphttp/mlflow` removido: redundante com integracao nativa. OTEL Collector permanece apenas para spanmetrics → Prometheus → Grafana (metrics operacionais).
- `OTEL_EXPORTER_OTLP_ENDPOINT` conflita com MLflow tracing: env var faz o OTEL SDK interno do MLflow enviar traces pro OTEL Collector ao inves do MLflow server. Fix: remover do ConfigMap. Claude Code telemetry usa config proprio.
- `opentelemetry-exporter-otlp-proto-http` obrigatorio no agent image: sem ele, `mlflow.start_span_no_context()` retorna `NoOpSpan`. Adicionado ao Dockerfile.
- `.claude/settings.json` precisa de `chmod g+w`: OpenShift roda com UID aleatorio mas GID=0. Sem group-write, `mlflow autolog claude` nao consegue escrever hooks.
- NetworkPolicy: agent-sandboxes egress e observability ingress precisam permitir porta 5000 (MLflow) alem de 4317/4318 (OTLP).
- Simplificacao: OTEL Collector + Prometheus + Grafana adicionavam complexidade (crashloops, NetworkPolicy, spanmetrics config) sem valor suficiente pro PoC. `mlflow autolog claude` fornece traces ricos nativamente. Componentes desabilitados, manifests mantidos.

**Artefatos:**

```
observability/
├── otel/                            # (disabled) OTEL Collector — kept for future re-enablement
│   ├── collector.yaml
│   └── service.yaml
├── prometheus/                      # (disabled) Prometheus — kept for future re-enablement
│   ├── configmap.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── mlflow/                          # (active) MLflow Tracking Server v3.10.1
│   ├── deployment.yaml
│   ├── pvc.yaml
│   ├── service.yaml
│   └── route.yaml
├── grafana/                         # (disabled) Grafana OSS — kept for future re-enablement
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── route.yaml
│   ├── configmap-datasources.yaml
│   └── configmap-dashboards.yaml
├── dashboards/                      # (disabled) Grafana dashboard JSON
│   └── agent-metrics.json
└── scripts/
    ├── config.sh                    # Env vars (namespace, paths, timeouts)
    ├── 01-deploy-observability.sh   # Deploy MLflow only
    └── 99-verify.sh                 # Verify MLflow
```

### 2.2 TrustyAI Guardrails (Fase 2)

- [ ] Instalar Red Hat OpenShift AI Operator
- [ ] Habilitar TrustyAI no DataScienceCluster (`managementState: Managed`)
- [ ] Deploy Guardrails Orchestrator CRD no namespace `inference`
- [ ] Configurar detector PII: email, telefone, CPF, cartao, IP (regex)
- [ ] Configurar detector de content filtering basico
- [ ] Validar: request com PII retorna `400 Blocked`
- [ ] Validar: request limpo passa pro vLLM e retorna resposta

**Artefatos:**

```
infra/guardrails/
├── manifests/
│   ├── guardrails-orchestrator.yaml # CRD do orchestrator
│   ├── orchestrator-config.yaml     # Config do orchestrator
│   └── gateway-config.yaml          # Rotas do gateway
├── scripts/                         # check, deploy, verify
```

### 2.3 NeMo Guardrails (Fase 2 — opcional, tech preview)

- [ ] Deploy NeMo Guardrails no namespace `inference`
- [ ] Criar Colang rules basicas (jailbreak, prompt injection)
- [ ] Configurar chain: Agent → TrustyAI → NeMo → vLLM
- [ ] Validar output rails (PII leak prevention na resposta)

**Artefatos:**

```
infra/nemo/
├── deployment.yaml
└── colang-rules/
    ├── input-rails.co               # Regras de input
    └── output-rails.co              # Regras de output
```

### 2.3a Migrar standalone pra Guardrails

- [ ] Atualizar ConfigMap `claude-code-config`: `ANTHROPIC_BASE_URL` → Guardrails endpoint
- [ ] Reiniciar pod standalone
- [ ] Validar: Claude Code continua respondendo via Guardrails → vLLM
- [ ] Validar: request com PII bloqueado no standalone tambem

### 2.4 Coder como CDE (Fase 3)

- [ ] Deploy PostgreSQL via OperatorHub no namespace `coder`
- [ ] Helm install Coder v2 com SecurityContext compativel com `restricted-v2`
- [ ] Criar Route OpenShift com TLS termination
- [ ] Configurar OIDC auth (OpenShift OAuth)
- [ ] Criar Terraform template reusando ConfigMap `claude-code-config` do Sprint 1:
  - Mesma imagem custom (UBI9 + Claude Code) ja validada
  - Git + ferramentas de dev
  - `envFrom: configMapRef: claude-code-config`
- [ ] Validar: dev acessa Coder UI, cria workspace, Claude Code responde

**Artefatos:**

```
coder/
├── postgres/
│   └── postgres.yaml                # Operator CR ou StatefulSet
├── helm/
│   └── values.yaml                  # Helm values pro Coder
├── route.yaml                       # Route com TLS
├── oauth/
│   └── oidc-config.yaml             # Configuracao OIDC
└── templates/
    └── claude-workspace/
        ├── main.tf                  # Terraform template
        └── variables.tf
```

### Gate do Sprint 2

| # | Criterio | Validacao |
|---|---|---|
| G2.1 | Traces de tool calls aparecem no MLflow (AC-6) | UI do MLflow |
| G2.2 | MLflow recebendo traces via `mlflow autolog claude` | UI do MLflow (experiment `claude-code-agents`) |
| G2.3 | Dados capturados: prompts, tokens, latencia, tools | Inspecionar traces |
| G2.4 | Request com PII bloqueado pelo TrustyAI (AC-5) | Teste com CPF/email no prompt |
| G2.5 | Request limpo chega no vLLM e retorna resposta | `curl` via Guardrails endpoint |
| G2.6 | Coder UI acessivel via Route com TLS | Browser |
| G2.7 | Dev cria workspace e Claude Code funciona (AC-1) | Teste manual end-to-end |
| G2.8 | Auth OIDC funciona (login via OpenShift) | Teste manual |

---

## Sprint 3 — Isolamento + Identidade (Semana 3)

> **Meta:** Workspaces rodando em Kata VMs. Agentes com identidade SPIFFE.
>
> **Fases PRD:** 4 + 5

### 3.1 Kata Containers (Fase 4) — Concluido no Sprint 1 (carry-over 2.0b)

> Kata foi antecipado pro Sprint 1. Ver secao 2.0b acima para detalhes completos.

- [x] Instalar Sandboxed Containers Operator v1.3.3 — feito no Sprint 1
- [x] Criar KataConfig CR e aguardar MCP kata-oc — feito no Sprint 1
- [x] Provisionar bare metal node (m5.metal) — EC2 VMs nao suportam /dev/kvm (ADR-017)
- [x] Validar KataConfig ready nos nodes (`oc get kataconfig -o yaml`)
- [x] Claude Code standalone rodando em Kata MicroVM — E2E OK
- [ ] Atualizar Terraform template do Coder: `runtimeClassName: kata`
- [x] NetworkPolicy restritiva em `agent-sandboxes` — feita no Sprint 1 (ADR-013)
- [x] Scripts: `03-install-kata.sh`, `04-validate-kata.sh`

**Artefatos:**

```
infra/cluster/
├── scripts/
│   ├── 03-install-kata.sh           # Install operator + KataConfig
│   └── 04-validate-kata.sh          # Validate Kata E2E (bare metal, /dev/kvm, test pod)
├── machinesets/
│   ├── gpu-l40s.yaml                # g6e.4xlarge (NVIDIA L40S)
│   └── kata-baremetal.json          # m5.metal (bare metal for Kata)
├── namespaces/
│   └── network-policies.yaml        # Regras restritivas (ADR-013)
coder/
└── templates/
    └── claude-workspace/
        └── main.tf                  # TODO: atualizar com runtimeClassName: kata
```

### 3.2 Kagenti + SPIFFE (Fase 5)

- [ ] Deploy SPIRE server no namespace `agentops`
- [ ] Deploy Kagenti Operator no namespace `agentops`
- [ ] Configurar labels `kagenti.io/type: agent` nos pods do workspace
- [ ] Validar auto-discovery: Kagenti detecta pods com label
- [ ] Validar sidecar injection: `spiffe-helper` e `kagenti-client-registration`
- [ ] Validar SVID no filesystem do pod
- [ ] Deploy Keycloak (ou usar existente)
- [ ] Configurar token exchange: SVID → OAuth2 token com claims (role, namespace, agent-id)

**Artefatos:**

```
agentops/
├── spire/
│   ├── server.yaml                  # SPIRE server deployment
│   ├── agent.yaml                   # SPIRE agent daemonset
│   └── registration-entries.yaml    # Entries pra workload attestation
├── kagenti/
│   ├── operator.yaml                # Kagenti Operator deployment
│   └── agentcard-sample.yaml        # Exemplo de AgentCard CRD
└── keycloak/
    ├── deployment.yaml              # Keycloak (se nao existir)
    └── realm-config.json            # Realm com token exchange
```

### Gate do Sprint 3

| # | Criterio | Validacao |
|---|---|---|
| G3.1 | `uname -r` dentro do workspace != `uname -r` do host (AC-2) | Exec no pod |
| G3.2 | NetworkPolicy bloqueia acesso nao-autorizado (AC-8) | `curl` pra service nao-permitido → timeout |
| G3.3 | SVID presente no filesystem do pod (AC-3) | `ls /run/spire/sockets/` |
| G3.4 | Token exchange funciona: SVID → JWT com claims | Teste via Keycloak |
| G3.5 | Kagenti cria AgentCard automaticamente | `oc get agentcards -n agent-sandboxes` |

---

## Sprint 4 — Governanca (Semana 4)

> **Meta:** Tools governadas por identidade.
>
> **Fases PRD:** 6

### 4.1 MCP Gateway (Fase 6)

- [ ] Instalar Sail Operator (Istio) via OperatorHub
- [ ] Instalar Gateway API CRDs
- [ ] Deploy MCP Gateway (Envoy-based) via Helm no namespace `mcp-gateway`
- [ ] Configurar MCP servers backend: GitHub, filesystem
- [ ] Instalar Kuadrant + Authorino
- [ ] Configurar AuthPolicy: validacao JWT dos tokens do Keycloak
- [ ] Definir policies OPA por role:
  - `developer`: filesystem read/write, github read
  - `senior-developer`: tudo de developer + github create_pr
  - `admin`: acesso total
- [ ] Configurar Claude Code: `MCP_URL` aponta pro gateway
- [ ] Validar: tool list filtrada por role do token
- [ ] Validar: tool call nao-autorizada retorna 403

**Artefatos:**

```
mcp-gateway/
├── helm/
│   └── values.yaml                  # Helm values pro MCP Gateway
├── gateway-api/
│   ├── gateway.yaml                 # Gateway resource
│   └── httproute.yaml               # Routes pros MCP servers
├── auth/
│   ├── authpolicy.yaml              # Kuadrant AuthPolicy
│   ├── authorino.yaml               # Authorino config
│   └── opa-policies/
│       ├── developer.rego           # Policy pra role developer
│       └── admin.rego               # Policy pra role admin
└── mcp-servers/
    ├── github.yaml                  # MCP server GitHub
    └── filesystem.yaml              # MCP server filesystem
```

### Gate do Sprint 4

| # | Criterio | Validacao |
|---|---|---|
| G4.1 | Tools filtradas por role do token no MCP Gateway (AC-4) | `tools/list` com tokens de roles diferentes |
| G4.2 | Tool call nao-autorizada retorna 403 | `tools/call` com token sem permissao |

---

## Sprint 5 — CI/CD + Integracao (Semana 5)

> **Meta:** Pipeline de safety scan. Teste end-to-end de toda a stack.
>
> **Fases PRD:** 8 + integracao

### 5.1 Tekton + Garak (Fase 8)

- [ ] Instalar Tekton Pipelines Operator via OperatorHub
- [ ] Criar Task `garak-scan`: roda Garak adversarial probes contra o vLLM
- [ ] Criar Task `agent-deploy`: deploy de agente via Kagenti
- [ ] Criar Task `smoke-test`: validacao basica pos-deploy
- [ ] Criar Pipeline: `garak-scan` → `agent-deploy` → `smoke-test`
- [ ] Configurar triggers (EventListener + TriggerTemplate)
- [ ] Validar: pipeline bloqueia deploy quando Garak detecta vulnerabilidade
- [ ] Validar: pipeline permite deploy quando scan passa

**Artefatos:**

```
cicd/
├── tekton/
│   ├── tasks/
│   │   ├── garak-scan.yaml          # Task de scan adversarial
│   │   ├── agent-deploy.yaml        # Task de deploy via Kagenti
│   │   └── smoke-test.yaml          # Task de validacao
│   ├── pipelines/
│   │   └── agent-safety-pipeline.yaml
│   └── triggers/
│       ├── event-listener.yaml
│       └── trigger-template.yaml
```

### 5.2 Integracao end-to-end

- [ ] Teste E2E completo:
  1. Dev acessa Coder → cria workspace
  2. Workspace roda em Kata VM
  3. Claude Code usa modelo local via Guardrails
  4. Tools acessadas via MCP Gateway (filtradas por role)
  5. Traces aparecem no MLflow
  6. PII bloqueado pelo TrustyAI
- [ ] Validar todos os criterios de aceitacao (AC-1 a AC-8)
- [ ] Medir metricas de sucesso (PRD secao 10)
- [ ] Documentar resultados e gaps

**Artefatos:**

```
docs/
├── results/
│   ├── acceptance-criteria.md       # Resultado de cada AC
│   ├── metrics.md                   # Metricas medidas vs targets
│   └── gaps.md                      # Gaps encontrados e proximos passos
```

### 5.3 Housekeeping

- [x] Criar README.md do repositorio
- [x] Criar `.gitignore`
- [ ] Revisar e atualizar docs com aprendizados
- [ ] Documentar troubleshooting / runbook

### Gate do Sprint 5

| # | Criterio | Validacao |
|---|---|---|
| G5.1 | Pipeline Tekton roda Garak e bloqueia modelo vulneravel (AC-7) | PipelineRun com falha proposital |
| G5.2 | Fluxo E2E funciona: Coder → Kata → Guardrails → vLLM → MCP → MLflow | Teste manual completo |
| G5.3 | Todos os 8 criterios de aceitacao passam | Checklist |
| G5.4 | Metricas documentadas vs targets do PRD | `docs/results/metrics.md` |

---

## Pos-PoC — Dev Spaces (Fase 9)

> **Meta:** Alternativa ao Coder usando Dev Spaces. Nao eh bloqueante pro PoC.

- [ ] Instalar Dev Spaces Operator
- [ ] Criar Devfile com Claude Code + tooling
- [ ] Integrar com vLLM / MCP Gateway / MLflow existentes
- [ ] Comparar DX: Coder vs Dev Spaces

---

## Pos-PoC — Agent Orchestration Governance (Fase 10)

> **Meta:** Investigar ferramentas de orquestracao multi-agente e definir camada de governanca para coordenar multiplos agentes em escala.
>
> **Referencia:** [Gastown](https://github.com/steveyegge/gastown) | [Multica](https://github.com/multica-ai/multica)

### 10.1 Research e Avaliacao

- [ ] Deploy local do [Gastown](https://github.com/steveyegge/gastown) (Go, multi-agent workspace manager, 13.8k stars)
  - Mayor (coordenador AI), Polecats (worker agents), Convoys (work tracking)
  - Hooks (git worktree persistence), Refinery (merge queue), OTEL telemetry
- [ ] Deploy local do [Multica](https://github.com/multica-ai/multica) (Next.js + Go + PostgreSQL, managed agents platform, 4.2k stars)
  - Agents as teammates (board/assignment), reusable skills, CLI daemon
- [ ] Testar ambos com Claude Code + vLLM local
- [ ] Avaliar contra requisitos AgentOps:
  - Compatibilidade com OpenShift (SCC, NetworkPolicy, rootless)
  - Integracao com Kata (runtimeClassName por agent)
  - Integracao com SPIFFE/Kagenti (identidade por agente)
  - Integracao com MLflow (traces multi-agente)
  - Compatibilidade com TrustyAI (guardrails por request, nao por agente)
- [ ] Comparar modelos de orquestracao:
  - Gastown: Mayor/convoy (AI coordinator, git-backed state, merge queue)
  - Multica: Board/assignment (human-driven, skills reuse, WebSocket streaming)
- [ ] Documentar findings em ADR (ADR-019 ou proximo)

### 10.2 Orquestracao PoC no OpenShift

- [ ] Containerizar ferramenta selecionada (ou hibrida) com UBI base image
- [ ] Adaptar pra SCC `restricted-v2` (rootless, read-only rootfs)
- [ ] Deploy no namespace `agentops`
- [ ] Integrar com stack existente:
  - vLLM (inference endpoint)
  - Kata (cada agente em microVM isolada)
  - MCP Gateway (tools governadas por identidade)
  - MLflow (traces por agente via `mlflow autolog claude`)
- [ ] Testar workflows multi-agente:
  - Execucao paralela de tasks (2-5 agentes simultaneos)
  - Distribuicao de trabalho (round-robin, skill-based, priority)
  - Resolucao de conflitos (merge queue, lock de arquivos)
- [ ] Validar health monitoring em escala (5-10 agentes concorrentes)
- [ ] Medir overhead de orquestracao (latencia, resource usage)

**Artefatos:**

```
orchestration/
├── manifests/
│   ├── deployment.yaml              # Orchestrator deployment
│   ├── service.yaml                 # ClusterIP service
│   ├── configmap.yaml               # Orchestrator config
│   └── pvc.yaml                     # State storage (se necessario)
├── scripts/
│   ├── 00-prerequisites.sh          # Dependency check
│   ├── 01-deploy.sh                 # Deploy orchestrator
│   └── 99-verify.sh                 # Validation
└── policies/
    ├── capacity.yaml                # Agent capacity limits
    ├── assignment.yaml              # Work assignment rules
    └── escalation.yaml              # Escalation policies
```

### 10.3 Camada de Governanca

- [ ] Definir policies de capacidade:
  - Max agentes concorrentes por namespace
  - Resource quotas por agente (CPU, memory, GPU time-share)
  - Scheduling: rate limiting de requests ao vLLM
- [ ] Definir regras de atribuicao de trabalho:
  - Role-based: junior agents (read-only tools) vs senior agents (write + PR)
  - Skill-based: agent specialization por linguagem/framework
  - Priority queues: critical fixes > features > chores
- [ ] Definir politicas de escalacao:
  - Human-in-the-loop gates (PR review, deploy approval)
  - Timeout-based escalation (agent stuck > N minutos)
  - Severity routing (P0 → human, P1 → senior agent, P2 → queue)
- [ ] Implementar audit trail:
  - Quem atribuiu o que a qual agente
  - Resultado de cada task (success/fail/escalated)
  - Tempo de execucao, tokens consumidos, tools usadas
  - Integracao com MLflow experiments
- [ ] Integrar com Kagenti identity:
  - SPIFFE SVID por instancia de agente
  - Token exchange com claims de role/skill
  - MCP Gateway policies por agente (nao so por role)

### Gate Pos-PoC — Orchestration

| # | Criterio | Validacao |
|---|---|---|
| G10.1 | Ferramenta avaliada e ADR documentado | ADR com decision rationale |
| G10.2 | Orchestrator rodando no OpenShift com 2+ agentes simultaneos | `oc get pods -n agentops` |
| G10.3 | Agentes isolados em Kata com identidade SPIFFE individual | SVID unico por agente |
| G10.4 | Work distribution funcional (task → agent → resultado) | E2E com 3+ tasks paralelas |
| G10.5 | Policies de capacidade enforced (max agents, rate limit) | Teste de overflow |
| G10.6 | Audit trail completo no MLflow | Traces com agent-id, task-id, outcome |

---

## Estrutura de artefatos (repositorio)

```
claude-code-openshift/
├── README.md
├── .gitignore
├── docs/
│   ├── PRD.md
│   ├── ARCHITECTURE.md
│   ├── PLAN.md                      ← este arquivo
│   ├── cluster-info.md              # Specs do cluster (Sprint 1)
│   ├── adrs/
│   ├── references/
│   └── results/                     # Resultados do PoC (Sprint 5)
├── infra/
│   ├── claude-code/                 # Agent image, entrypoint, manifests, scripts
│   ├── cluster/                     # Operators, NS, NetworkPolicy, Quotas, RBAC, Kata, MachineSets
│   ├── vllm/                        # Upstream vLLM model serving (Deployment+Service)
│   ├── scripts/                     # deploy-all.sh, e2e-test.sh
│   ├── guardrails/                  # TrustyAI config
│   └── nemo/                        # NeMo Guardrails (opcional)
├── coder/
│   ├── helm/                        # Helm values do Coder
│   ├── postgres/                    # PostgreSQL
│   ├── oauth/                       # OIDC config
│   └── templates/                   # Terraform workspace templates
├── agentops/
│   ├── spire/                       # SPIRE server/agent
│   ├── kagenti/                     # Kagenti Operator
│   └── keycloak/                    # Keycloak / token exchange
├── mcp-gateway/
│   ├── helm/                        # MCP Gateway
│   ├── gateway-api/                 # Gateway + HTTPRoutes
│   ├── auth/                        # AuthPolicy + OPA
│   └── mcp-servers/                 # GitHub, filesystem
├── observability/
│   ├── otel/                        # OTEL Collector (disabled — kept for future use)
│   ├── mlflow/                      # MLflow Tracking Server v3.10.1 (active)
│   ├── prometheus/                  # Prometheus (disabled — kept for future use)
│   ├── grafana/                     # Grafana (disabled — kept for future use)
│   ├── dashboards/                  # Grafana dashboard JSON (disabled)
│   └── scripts/                     # Deploy + verify scripts (MLflow-only)
├── orchestration/
│   ├── manifests/                   # Orchestrator deployment + config
│   ├── scripts/                     # Deploy, verify
│   └── policies/                    # Capacity, assignment, escalation
└── cicd/
    └── tekton/                      # Tasks, Pipelines, Triggers
```

---

## Dependencias entre sprints

```mermaid
flowchart LR
    S1[Sprint 1<br>Infra + vLLM<br>+ Claude standalone] --> GoNoGo{Go/No-Go<br>modelo}
    GoNoGo -->|Go| S2[Sprint 2<br>Observability +<br>Safety + Coder]
    GoNoGo -->|No-Go| Fix[Escalar modelo<br>ou mudar approach]
    Fix --> S1
    S2 --> S3[Sprint 3<br>Kata + Kagenti]
    S3 --> S4[Sprint 4<br>MCP Gateway]
    S4 --> S5[Sprint 5<br>CI/CD + E2E]
    S5 --> PostPoC[Pos-PoC<br>Dev Spaces +<br>Agent Orchestration]

    S1 -->|"vLLM + agente validado"| S2
    S2 -->|"MLflow + Guardrails + Coder"| S3
    S3 -->|"SPIFFE tokens"| S4
    S4 -->|"Stack completa"| S5
    S5 -->|"Stack validada E2E"| PostPoC
```

**Dependencias criticas:**
- Sprint 1 tem **go/no-go**: agente + modelo funcionam? Se nao, resolve antes de investir no resto
- Sprint 2 depende do vLLM + agente standalone validados (Sprint 1). Observabilidade primeiro (sem deps, traces ajudam a debugar o resto)
- Sprint 3 depende do Coder funcional (Sprint 2) pra testar Kata nos workspaces
- Sprint 4 depende dos tokens SPIFFE (Sprint 3) pra autenticar no MCP Gateway
- Sprint 5 eh integracao — depende de tudo
- Pos-PoC (Orchestration) depende da stack completa validada (Sprint 5) — multi-agente precisa de identity, guardrails, MLflow e MCP Gateway funcionais

---

## Riscos por sprint

| Sprint | Risco principal | Mitigacao |
|---|---|---|
| 1 | Cluster sem nested virt → Kata nao funciona | ✅ Resolvido: bare metal m5.metal provisionado (ADR-017). gVisor nao suportado em OpenShift. |
| 1 | GPU insuficiente pro modelo | Quantizacao agressiva (Q5) ou Qwen 7B |
| 1 | Claude Code incompativel com API do vLLM/Qwen | Testar no standalone; ajustar env vars ou modelo |
| 1 | Qwen 2.5 14B gera codigo ruim | Go/no-go no Sprint 1; escalar antes de investir no resto |
| 2 | MLflow storage insuficiente para traces | Monitorar PVC usage; expandir ou usar S3 |
| 2 | Coder SCC conflicts com restricted-v2 | Seguir doc oficial; testar com anyuid se necessario |
| 2 | TrustyAI latencia alta | Medir; desabilitar detectors pesados |
| 3 | Kagenti alpha — breaking changes | Pintar versao; manter workaround manual |
| 4 | MCP Gateway tech preview — instavel | Pintar versao; configuracao estatica como fallback |
| 5 | Garak scan demora demais | Limitar probes; timeout na pipeline |
| Pos-PoC | Gastown/Multica incompativel com OpenShift SCC | Testar rootless; adaptar Dockerfile com UBI base |
| Pos-PoC | Resource contention com multiplos agentes (CPU, GPU, vLLM queue) | Scheduling policies; rate limiting no orchestrator |
| Pos-PoC | Merge conflicts entre agentes trabalhando no mesmo repo | Merge queue (Refinery pattern); lock de arquivos; particionamento de tasks |
