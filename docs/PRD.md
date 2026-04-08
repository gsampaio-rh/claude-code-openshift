# PRD: AgentOps Platform — Claude Code on OpenShift

**Status:** Draft
**Autor:** Platform Engineering
**Data:** 2026-04-08
**Tipo:** PoC
**Publico-alvo:** 5-20 desenvolvedores simultaneos

---

## 1. Problema

Times de desenvolvimento querem usar AI coding agents (Claude Code) para acelerar produtividade, mas deployar agentes em producao sem guardrails cria riscos:

- **Seguranca:** agentes executam codigo nao-confiavel com acesso a repos, credenciais e APIs
- **Compliance:** sem audit trail de o que o agente fez, quando, e com quais dados
- **Isolamento:** agentes rodando em containers padrao compartilham kernel com o host
- **Governanca:** sem controle de quais ferramentas (MCP tools) cada agente pode acessar
- **Safety:** prompts podem conter PII, jailbreaks, ou prompt injections que chegam direto no modelo
- **Custo:** dependencia de APIs cloud (Anthropic) sem opcao de inferencia local

## 2. Objetivo

Montar um ambiente PoC no cluster OpenShift existente que roda Claude Code como coding agent com enterprise rigor, validando a stack completa de AgentOps da Red Hat AI.

O PoC deve provar que eh possivel:

1. Rodar agentes em microVMs isoladas (Kata)
2. Dar identidade criptografica a cada agente (SPIFFE/Kagenti)
3. Servir modelos localmente sem custo de API (vLLM)
4. Interceptar inputs/outputs com guardrails (TrustyAI/NeMo)
5. Governar acesso a tools por identidade (MCP Gateway)
6. Rastrear todas as acoes do agente (MLflow/OTEL)
7. Scanear modelos antes de deploy (Garak/Tekton)
8. Dar aos devs um CDE com Claude Code pre-configurado (Coder)

## 3. Stack tecnologica

| Categoria | Tecnologia | Status |
|---|---|---|
| Agente | Claude Code (headless + interativo) | GA |
| Isolamento | OpenShift Sandboxed Containers (Kata) | GA |
| Identidade | Kagenti Operator + SPIFFE/SPIRE | Alpha |
| Inferencia | vLLM / Red Hat AI Inference Server (Qwen 2.5 14B) | GA |
| Governanca de tools | MCP Gateway (Envoy + Kuadrant AuthPolicy) | Tech Preview |
| Observabilidade | MLflow + OpenTelemetry | Dev Preview |
| Safety (runtime) | TrustyAI Guardrails Orchestrator + NeMo Guardrails | GA / Tech Preview |
| Safety (pre-deploy) | Garak adversarial scanner | Planned |
| Lifecycle | Kagenti Operator (AgentCard CRD) | Alpha |
| CDE | Coder (inicial), Dev Spaces (futuro) | GA |
| CI/CD | Tekton Pipelines | GA |
| Auth | OpenShift RBAC + OAuth | GA |

## 4. Usuarios e personas

**Dev (5-20 pessoas):** Usa Coder para abrir workspace com VS Code. Claude Code esta pre-instalado. Interage via terminal ou IDE. Nao precisa saber nada sobre Kata, SPIFFE, ou MCP Gateway — a plataforma cuida.

**Platform Engineer (1-2 pessoas):** Instala e mantem a stack. Configura policies, NetworkPolicies, operators. Monitora MLflow e dashboards.

**Security/Compliance:** Audita traces no MLflow. Valida que guardrails estao ativos. Revisa policies do MCP Gateway.

## 5. Fases de implementacao

### Fase 0 — Pre-requisitos e infra base (semana 1)

Validar o cluster e instalar operators base.

**Deliverable:** Cluster pronto com operators instalados, namespaces criados, RBAC configurado.

**Tasks:**
- Validar versao do OpenShift (4.16+), acesso admin, GPU disponivel
- Instalar NVIDIA GPU Operator + Node Feature Discovery
- Instalar OpenShift Sandboxed Containers Operator (Kata) via OperatorHub
- Criar KataConfig CR para habilitar runtime Kata nos nodes
- Instalar cert-manager Operator
- Criar namespaces: `coder`, `agentops`, `agent-sandboxes`, `inference`, `mcp-gateway`, `observability`, `cicd`
- Configurar NetworkPolicy base entre namespaces
- Criar ResourceQuota por namespace

### Fase 1 — Inferencia local com vLLM (semana 1-2)

Subir o modelo Qwen 2.5 14B no cluster.

**Deliverable:** Endpoint `/v1/messages` respondendo no cluster.

**Tasks:**
- Deploy vLLM via Helm chart rhai-helm
- Configurar Qwen/Qwen2.5-14B-Instruct (FP16 se GPU >= 28GB, Q8 se >= 16GB, Q5 se >= 12GB)
- Validar endpoint com curl direto no pod
- Criar Service + Route interna (nao expor externamente)

**Requisitos de GPU:**
- FP16: ~28GB VRAM (A100/H100)
- Q8: ~15GB VRAM (A10G, RTX 4090)
- Q5_K_M: ~11GB VRAM (RTX 4060 Ti 16GB)

### Fase 2 — Safety na boundary de inferencia (semana 2)

Colocar guardrails entre os agentes e o modelo.

**Deliverable:** Requests passam por TrustyAI antes de chegar no vLLM.

**Tasks:**
- Habilitar TrustyAI no DataScienceCluster (managementState: Managed)
- Deploy Guardrails Orchestrator CRD no namespace inference
- Configurar detectors: PII (regex), content filtering
- Deploy NeMo Guardrails (tech preview) com Colang rules basicas
- Validar: request com PII bloqueado antes de chegar no vLLM

### Fase 3 — Coder como CDE (semana 2-3)

Instalar Coder no OpenShift para dar workspaces isolados aos devs.

**Deliverable:** Devs acessam Coder via browser, criam workspaces com Claude Code.

**Tasks:**
- Deploy PostgreSQL via OperatorHub
- Helm install Coder com SecurityContext compativel com restricted-v2
- Criar Route OpenShift com TLS termination
- Criar Terraform template com Claude Code pre-instalado
- Configurar OIDC auth (OpenShift OAuth)

### Fase 4 — Isolamento com Kata (semana 3)

Rodar workspaces/agentes dentro de microVMs Kata.

**Deliverable:** Pods rodam com runtimeClassName: kata em microVM isolada.

**Tasks:**
- Validar KataConfig ready nos nodes
- Atualizar Terraform template do Coder para usar runtimeClassName: kata
- Testar: workspace roda em Kata VM (kernel separado)
- Configurar NetworkPolicy restritiva

### Fase 5 — Kagenti: identidade e lifecycle (semana 3-4)

Dar identidade criptografica e lifecycle management aos agentes.

**Deliverable:** Agentes tem SPIFFE identity, auto-descobertos via AgentCard.

**Tasks:**
- Deploy Kagenti Operator no namespace agentops
- Deploy SPIRE server
- Configurar labels kagenti.io/type: agent nos pods
- Validar auto-discovery e sidecar injection
- Configurar Keycloak para token exchange

### Fase 6 — MCP Gateway: governanca de tools (semana 4)

Controlar quais ferramentas cada agente pode acessar.

**Deliverable:** Agentes acessam tools via MCP Gateway, filtrados por identidade.

**Tasks:**
- Instalar Gateway API CRDs + Istio (Sail Operator)
- Deploy MCP Gateway via Helm
- Configurar MCP servers backend: GitHub, filesystem
- Configurar Kuadrant AuthPolicy + Authorino (JWT validation)
- Definir policies OPA por role
- Configurar Claude Code: MCP_URL aponta pro gateway

### Fase 7 — Observabilidade (semana 4-5)

Capturar traces de tudo que os agentes fazem.

**Deliverable:** Dashboard MLflow com traces de tool calls, tokens, reasoning.

**Tasks:**
- Deploy OTEL Collector
- Configurar Claude Code para emitir OTEL traces
- Deploy MLflow Tracking Server
- Criar dashboards: tokens/hora, tool calls/agente, latencia

### Fase 8 — CI/CD com Tekton + Garak (semana 5)

Pipeline de safety scan antes de promover agentes/modelos.

**Deliverable:** Pipeline Tekton que roda Garak scan e bloqueia deploy se falhar.

**Tasks:**
- Instalar Tekton Pipelines Operator
- Criar Task: garak-scan (adversarial probes)
- Criar Task: agent-deploy (via Kagenti)
- Criar Pipeline: garak-scan -> agent-deploy
- Configurar triggers

### Fase 9 — Dev Spaces (pos-PoC)

Adicionar Dev Spaces como CDE alternativo.

**Tasks:**
- Instalar Dev Spaces Operator
- Criar Devfile com Claude Code + tooling
- Integrar com vLLM/MCP Gateway/OTEL existentes

## 6. Requisitos de infra

### Cluster OpenShift

- Versao: 4.16+ (recomendado 4.18+)
- Nodes: minimo 3 workers + 1 com GPU
- Bare metal ou virtualizacao com nested virt (para Kata)
- Storage: PVs disponiveis (PostgreSQL, MLflow)

### GPU

- Minimo: 1x GPU 12GB+ VRAM (quantizado)
- Recomendado: 1x GPU 24-28GB VRAM (FP16)
- Exemplos: A10G (24GB), RTX 4090 (24GB), A100 (40/80GB)

### Rede

- Egress: GitHub, npm, registries (via NetworkPolicy)
- Interno: Service/ClusterIP entre namespaces
- Ingress: Coder UI via Route com TLS

### Operators necessarios (OperatorHub)

| Operator | Fase |
|---|---|
| NVIDIA GPU Operator | 0 |
| Node Feature Discovery Operator | 0 |
| OpenShift Sandboxed Containers Operator | 0 |
| cert-manager Operator | 0 |
| Red Hat OpenShift AI Operator | 2 |
| Tekton Pipelines Operator | 8 |
| Sail Operator (Istio) | 6 |

## 7. Criterios de aceitacao

| # | Criterio | Fase |
|---|---|---|
| AC-1 | Dev cria workspace no Coder, abre VS Code, Claude Code funciona com modelo local | 3 |
| AC-2 | Workspace roda em Kata VM (uname -r diferente do host) | 4 |
| AC-3 | Agente tem SPIFFE identity (SVID no filesystem do pod) | 5 |
| AC-4 | Tools filtradas por role do token no MCP Gateway | 6 |
| AC-5 | Prompt com PII interceptado pelo TrustyAI | 2 |
| AC-6 | Traces de tool calls e reasoning aparecem no MLflow | 7 |
| AC-7 | Pipeline Tekton roda Garak scan e bloqueia modelo vulneravel | 8 |
| AC-8 | NetworkPolicy impede agente de acessar services nao-autorizados | 4 |

## 8. Riscos e mitigacoes

| Risco | Impacto | Probabilidade | Mitigacao |
|---|---|---|---|
| Kata precisa de bare metal ou nested virt | Bloqueante | Media | Validar na Fase 0; fallback para gVisor |
| Kagenti e MCP Gateway sao alpha/TP | Breaking changes | Alta | Pintar versoes; manter fork se necessario |
| Qwen 2.5 14B insuficiente para coding | Qualidade baixa | Media | Testar com prompts reais na Fase 1; escalar modelo |
| VRAM insuficiente | Nao roda modelo | Baixa | Qwen 7B ou quantizacao agressiva |
| Coder SCC conflicts no OpenShift | Bloqueia CDE | Media | Seguir doc oficial; testar com restricted-v2 |
| TrustyAI/NeMo adicionam latencia | UX degradada | Baixa | Medir latencia na Fase 2; ajustar detectors |

## 9. Fora de escopo (PoC)

- Multi-tenancy com isolamento entre times (namespaces separados por time)
- HA/DR para vLLM ou MLflow
- Auto-scaling de agentes baseado em demanda
- Integracao com Jira/Slack/Telegram (apenas MCP servers basicos)
- Billing/chargeback por dev
- Modelo de producao (Qwen 14B eh para PoC; producao pode exigir modelo maior)

## 10. Metricas de sucesso

| Metrica | Target |
|---|---|
| Tempo de setup de workspace (Coder + Claude Code) | < 2 min |
| Latencia de inferencia (prompt simples) | < 5s |
| % de prompts com PII detectados pelo TrustyAI | > 95% |
| Cobertura de traces no MLflow | 100% das sessoes |
| Garak pass rate (modelo sem vulnerabilidades conhecidas) | > 90% |
| Devs conseguem usar Claude Code sem conhecer a infra | 100% |
