# Future explorations — backlog de sprints

**Status:** Backlog
**Data:** 2026-04-10
**Atualizado:** 2026-04-13
**Relacionado:** [PLAN.md](PLAN.md) | [ADR-019 — Observability](adrs/019-observability-otel-mlflow-grafana.md)

Temas que ficam **fora do núcleo imediato do PoC**, mas merecem tempo dedicado. Cada bloco abaixo pode virar uma sprint de exploração quando houver capacidade.

---

## Sprint A — Observability do modelo (vLLM / inferência) ✅ Concluído

**Objetivo:** Medir e visualizar o **runtime de inferência** — filas, latência, throughput de tokens, saúde do endpoint.

**Implementado (2026-04-13):**

- **User workload monitoring** habilitado no cluster (`enableUserWorkload: true`)
- **ServiceMonitor** para o vLLM — scrape de 97 métricas nativas a cada 15s (`infra/vllm/manifests/servicemonitor.yaml`)
- **Grafana** re-habilitado com datasource Thanos Querier (ServiceAccount `grafana` com `cluster-monitoring-view`)
- **Dashboard "AgentOps — Inference Metrics (vLLM)"** (`observability/dashboards/inference-metrics.json`):
  - **Model & Usage** — modelo servido, prompt/generation/total tokens, avg tokens/request, requests por finish reason, tokens por source (compute vs cache hit), throughput
  - **Request Overview** — running, waiting, KV cache, request rate, preemptions, engine state
  - **Latency** — TTFT, ITL, E2E (p50/p95/p99), queue wait, prefill, decode
  - **Cache & Engine** — KV cache over time, prefix cache hit rate, running vs waiting
  - **Process & System** — memory (RSS/virtual), CPU, iteration tokens
- **NetworkPolicy** atualizada para permitir Prometheus scrape e Grafana → Thanos

**Critérios de saída:**

- [x] Métricas do vLLM visíveis no Prometheus (user workload monitoring) e Grafana
- [x] Dashboard de inferência validado sob carga de teste (25 requests)
- [x] Manifests no repo para reproduzir

**Não implementado (futuro):**

- Métricas de GPU via DCGM (requer DCGM exporter)
- Breakdown por cliente/caller (requer proxy com identity labels — planejado com SPIFFE/Kagenti)
- Runbooks de troubleshooting

---

## Sprint B — Models-as-a-Service (OpenShift AI)

**Objetivo:** Explorar **MaaS** como camada de governança de LLM (tiers, quotas, API keys, roteamento) **separada** da observabilidade de inferência (Sprint A), usando a UI e o fluxo descritos na documentação Red Hat.

**Referência principal (interface do dashboard):**
[Govern LLM access with Models-as-a-Service — Understanding the MaaS dashboard interface](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index#understanding-the-maas-dashboard-interface_maas-user)

**O que a doc descreve (resumo para a sprint):**

- **Onde fica na UI:** dashboard OpenShift AI → **Gen AI studio** → **AI asset endpoints** → separador **Models as a service**. A página lista modelos publicados no MaaS (nome, badge MaaS, estado, endpoint de inferência, ações como playground).
- **Habilitar a UI:** `OdhDashboardConfig` com `spec.dashboardConfig.genAiStudio: true` e `spec.dashboardConfig.modelAsService: true` (e componente MaaS ativo); verificação com `oc get odhdashboardconfig` em `redhat-ods-applications`.
- **Experiência de utilizador:** descoberta de modelos, geração de tokens/credenciais, integração via APIs compatíveis com OpenAI; rota MaaS e gestão de acesso por tier.
- **Pré-requisitos e dependências (guia completo no mesmo manual):** por exemplo KServe gerido, **Kuadrant** (auth/rate limit), **Gateway API** / gateway `maas-default-gateway`, **Red Hat Connectivity Link** na versão indicada; para algumas funcionalidades de dashboard, **Llama Stack Operator** e requisitos de versão de cluster conforme o capítulo de instalação.

**Aviso:** Na documentação 3.4, MaaS consta como **Technology Preview** (sem SLA de produção). Validar sempre o texto atual em [Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index).

**Escopo sugerido:**

- Confirmar **pré-requisitos** do cluster (versão OCP, operators, `DataScienceCluster`, gateway) contra o manual antes de ativar MaaS.
- Habilitar **componente MaaS** e **dashboard** (`genAiStudio`, `modelAsService`); percorrer **AI asset endpoints** e o separador **Models as a service** conforme a secção *Understanding the MaaS dashboard interface*.
- Definir **tiers** de teste (grupos, rate limits, quotas) e publicar um modelo com **Distributed inference / llm-d** se for o runtime suportado para integração MaaS na doc.
- Registar **decisão ou não-decisão**: MaaS entra no desenho alvo ou fica como opção futura.

**Critérios de saída (exemplo):**

- [ ] Fluxo admin + utilizador documentado (screenshots ou checklist) a partir do dashboard.
- [ ] Lista de gaps vs. ambiente atual (operators, gateway, GPU, modelo publicável).
- [ ] Atualização mínima em [PLAN.md](PLAN.md) ou ADR se MaaS for adotado ou explicitamente postergado.

---

## Sprint C — Observability do agente (Claude Code OTel → Prometheus) ✅ Concluído

**Objetivo:** Exportar métricas do **agente Claude Code** para o Prometheus do cluster via OpenTelemetry, complementando a observabilidade de inferência (Sprint A) com visibilidade sobre o **uso, custo, e comportamento do agente**.

**Implementado (2026-04-13):**

- **OTEL Collector re-habilitado** no namespace `observability` — recebe métricas OTLP do agente e exporta via Prometheus endpoint (:8889)
- **Claude Code telemetry** habilitado via `CLAUDE_CODE_ENABLE_TELEMETRY=1` + `OTEL_METRICS_EXPORTER=otlp`
- Usa `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` (metrics-specific) para não conflitar com MLflow tracing
- **ServiceMonitor** para o OTEL Collector (`observability/otel/servicemonitor.yaml`)
- **Dashboard "AgentOps — Claude Code Agent Metrics"** (`observability/dashboards/agent-metrics.json`) — 5 seções, 42 painéis:
  - **Token Usage** — input, output, cache read/creation, total tokens, estimated cost (USD), rate over time, tokens por modelo
  - **Derived Efficiency Metrics** — cache hit rate, avg cost/session, avg tokens/session, output/input ratio, LOC per 1K tokens, commits/session, cache hit rate over time, cumulative cost
  - **Sessions & Activity** — sessions started, unique sessions, active time, lines of code, commits, PRs, LOC (added vs removed), active time (user vs CLI), tool decisions (accept/reject)
  - **MLflow Trace Metrics** — total traces, total LLM calls, avg agent/LLM span duration, span duration over time, LLM latency distribution (p50/p90/p99)
  - **Container Resources** — memory working set vs requested, CPU requests, pod restarts, memory over time, network I/O
- **OTel events/logs habilitado** — `OTEL_LOGS_EXPORTER=otlp` envia eventos do agente ao OTEL Collector (debug exporter → `oc logs`)
- **NetworkPolicy** atualizada: agent → OTEL Collector (:4318), Prometheus → OTEL Collector (:8889)

**Decisão de arquitetura: OTLP → OTEL Collector (opção 2)**

A opção 1 (Prometheus exporter direto, `OTEL_METRICS_EXPORTER=prometheus`) **não funciona** para o caso de uso atual: o exporter expõe um HTTP server na porta 9464, mas ele só roda enquanto o processo `claude` está ativo. Como sessões são efêmeras (`claude -p "..." → exit`, o entrypoint é `sleep infinity`), o endpoint desaparece entre sessões e o Prometheus perde os dados. O OTEL Collector resolve isso: métricas são **pushed** durante a sessão e o collector **persiste** e agrega os dados mesmo após o processo terminar.

**Métricas capturadas (validadas):**

| Métrica Prometheus | Labels |
|---|---|
| `claude_code_token_usage_tokens_total` | `type` (input/output/cacheRead/cacheCreation), `model`, `session_id` |
| `claude_code_cost_usage_USD_total` | `model`, `session_id` |
| `claude_code_session_count_total` | `session_id` |
| `claude_code_lines_of_code_count_total` | `type` (added/removed), `session_id` |
| `claude_code_commit_count_total` | `session_id` |
| `claude_code_pull_request_count_total` | `session_id` |
| `claude_code_code_edit_tool_decision_total` | `tool_name`, `decision`, `session_id` |
| `claude_code_active_time_total_s_total` | `type` (user/cli), `session_id` |

**Critérios de saída:**

- [x] Métricas do Claude Code (tokens, custo, sessões) visíveis no Grafana via Prometheus
- [x] Dashboard de agente com breakdown por sessão
- [x] Decisão documentada: OTLP → OTEL Collector (Prometheus exporter não funciona para sessões efêmeras)
- [x] ServiceMonitor e NetworkPolicy no repo

**Não implementado (futuro):**

- **Backend de logs queryable** — eventos/logs fluem ao OTEL Collector mas exportam apenas via `debug` (stdout). Precisa de Loki/Elasticsearch para queries.
- Traces beta via `OTEL_TRACES_EXPORTER=otlp` (distributed tracing prompt → tools → LLM)
- `OTEL_RESOURCE_ATTRIBUTES` para labels de equipe em multi-tenant
- Breakdown por `user.account_uuid` / `user.email` (requer OAuth no agente)

---

## Sprint D — Observability: próximos passos

**Objetivo:** Fechar os gaps que ficaram de fora dos Sprints A e C. Ver também [OBSERVABILITY.md §4](OBSERVABILITY.md).

### D.1 — Métricas de GPU (DCGM)

**O que falta:** Não temos visibilidade de utilização real de GPU (SM occupancy, memory bandwidth, temperatura, power draw). As métricas do vLLM (KV cache, tokens/s) são proxies indiretos.

**Como fazer:**
- Instalar **DCGM Exporter** nos nodes GPU (DaemonSet ou via GPU Operator, que já inclui DCGM)
- Criar ServiceMonitor para o DCGM Exporter
- Adicionar painel "GPU" no dashboard de inferência: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP`
- Referência: [NVIDIA GPU Operator — DCGM Exporter](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-dcgm-exporter.html)

### D.2 — Breakdown por cliente/caller

**O que falta:** Não conseguimos saber *quem* está fazendo requests ao modelo. O vLLM não tagga métricas por caller, e o agent OTel tem `session_id` mas não tem identidade de usuário.

**Como fazer:**
- **Curto prazo:** Habilitar `OTEL_RESOURCE_ATTRIBUTES="team.id=<team>,cost_center=<cc>"` no ConfigMap de cada agente. Permite segmentar por equipe no Grafana.
- **Médio prazo:** Com SPIFFE/Kagenti (Sprint 3 do PLAN), cada agente terá identidade criptográfica. Um proxy (Envoy/HAProxy) na frente do vLLM pode injetar headers `X-Agent-ID` e o vLLM pode logar por caller.
- **Longo prazo:** OAuth no agente (`user.account_uuid`, `user.email` nos atributos OTel) + MaaS (Sprint B) para governança completa.

### D.3 — OTel events/logs do agente (parcialmente implementado)

**O que já funciona:** `OTEL_LOGS_EXPORTER=otlp` habilitado. Eventos do agente (prompt events, tool results, API requests) fluem para o OTEL Collector via OTLP. O collector exporta via `debug` exporter — logs visíveis em `oc logs deploy/otel-collector -n observability`.

**O que falta:** Backend de logs queryable para correlacionar eventos com métricas no Grafana.

**Como fazer:**
- Deploy **Loki** (ou Elasticsearch) no cluster — OpenShift Logging (Loki Operator) é opção nativa
- Adicionar exporter `loki` na pipeline de logs do OTEL Collector (substituir `debug`)
- Configurar Loki como datasource no Grafana
- Criar dashboards de logs correlacionados com métricas (debugging de falhas de tool, análise de prompts que causam erros, auditoria de uso)

### D.4 — OTel traces (beta) do agente

**O que falta:** Distributed tracing que liga cada prompt do usuário às execuções de tools e chamadas de API. O Claude Code propaga `TRACEPARENT` para subprocessos, permitindo trace E2E.

**Como fazer:**
- Setar `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` e `OTEL_TRACES_EXPORTER=otlp`
- Adicionar pipeline de traces no OTEL Collector: receiver OTLP → exporter para **Tempo** ou **Jaeger**
- Grafana Tempo como datasource para visualizar waterfalls
- Diferente do MLflow: traces OTel são infraestrutura (latência, spans, erros); MLflow traces são semânticos (tool calls, conversas, tokens)

**Pré-requisito:** Deploy de Tempo ou Jaeger no cluster. OpenShift distributed tracing (Tempo Operator) é opção nativa.

### D.5 — Alerting (PrometheusRule)

**O que falta:** Nenhum alerta configurado. Se o modelo cair, a latência explodir, ou o custo disparar, ninguém é notificado.

**Como fazer:**
- Criar `PrometheusRule` CRDs no user workload monitoring
- Alertas sugeridos:
  - `vLLM_HighLatency`: TTFT p99 > 10s por 5 min
  - `vLLM_Down`: `up{job="qwen25-14b"} == 0` por 2 min
  - `vLLM_KVCacheFull`: KV cache usage > 95% por 5 min
  - `Agent_HighCost`: `rate(claude_code_cost_usage_USD_total[1h]) > threshold`
  - `Agent_HighTokens`: `rate(claude_code_token_usage_tokens_total[5m]) > threshold`
  - `OTEL_Collector_Down`: `up{job="otel-collector"} == 0` por 2 min
- Integrar com AlertManager (Slack, PagerDuty, email)

### D.6 — Runbooks de troubleshooting

**O que falta:** Guias práticos para diagnosticar problemas comuns usando os dashboards.

**Runbooks sugeridos:**
- **"Serving lento"** — Checar TTFT/ITL no dashboard → KV cache usage → requests waiting → GPU metrics (D.1) → escalar replicas ou modelo menor
- **"Endpoint não scrapeado"** — Verificar `up` metric → ServiceMonitor labels → NetworkPolicy → Prometheus targets
- **"GPU saturada"** — DCGM metrics (D.1) → KV cache pressure → batch size → model quantization
- **"Custo alto do agente"** — Dashboard agent → tokens por sessão → cache hit rate → otimizar prompts / max_output_tokens
- **"OTEL Collector sem dados"** — Verificar logs do collector → NetworkPolicy agent → observability:4318 → `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` no ConfigMap

---

## Nota

**Observability (Sprint A)** responde a *como o modelo/serving (vLLM, GPU, endpoint) se comporta e como depuramos gargalos de inferência*. **Sprint C** responde a *como os agentes consomem recursos (tokens, custo, tempo) e quem está usando*. **Sprint D** fecha os gaps restantes: GPU, identidade, logs, traces, alertas, runbooks. **MaaS (Sprint B)** responde a *como governamos o acesso aos modelos (API, tiers, quotas)*. Telemetria de **experimentos e traces detalhados** do agente permanece via MLflow conforme ADR-019.
