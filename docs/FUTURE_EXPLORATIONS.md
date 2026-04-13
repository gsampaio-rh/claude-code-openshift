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

## Sprint C — Observability do agente (Claude Code OTel → Prometheus)

**Objetivo:** Exportar métricas e eventos do **agente Claude Code** para o Prometheus do cluster via OpenTelemetry, complementando a observabilidade de inferência (Sprint A) com visibilidade sobre o **uso, custo, e comportamento do agente**.

**Contexto:** Claude Code tem suporte nativo a OpenTelemetry (metrics + logs/events + traces beta). Basta setar env vars no pod do agente. Referência oficial: [Claude Code Monitoring](https://docs.anthropic.com/en/docs/claude-code/monitoring).

**Métricas disponíveis (built-in):**

| Métrica | Descrição |
|---|---|
| `claude_code.token.usage` | Tokens consumidos (input, output, cacheRead, cacheCreation) por modelo |
| `claude_code.cost.usage` | Custo estimado em USD por sessão |
| `claude_code.session.count` | Sessões iniciadas |
| `claude_code.lines_of_code.count` | Linhas adicionadas/removidas |
| `claude_code.commit.count` | Commits criados |
| `claude_code.pull_request.count` | PRs criados |
| `claude_code.code_edit_tool.decision` | Accept/reject de ferramentas de edição |
| `claude_code.active_time.total` | Tempo ativo (user interaction vs CLI processing) |

**Eventos (via logs exporter):**

- `claude_code.user_prompt` — cada prompt submetido (length, opcionalmente conteúdo)
- `claude_code.tool_result` — execução de tools (nome, sucesso, duração, erro)
- `claude_code.api_request` — requests ao LLM (modelo, custo, tokens, duração)
- `claude_code.api_error` — erros de API (status code, retries)
- `claude_code.tool_decision` — decisões accept/reject de tools

**Traces (beta):**

- Spans ligando prompt → API requests → tool executions
- `TRACEPARENT` propagado para subprocessos (distributed tracing E2E)
- Requer `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` e `OTEL_TRACES_EXPORTER=otlp`

**Opções de arquitetura no OpenShift:**

1. **Prometheus exporter direto** — `OTEL_METRICS_EXPORTER=prometheus` expõe métricas no pod; scrape via `PodMonitor`. Simples, sem collector intermediário, métricas vão direto pro user workload monitoring (como vLLM).
2. **OTLP → OTEL Collector → Prometheus** — `OTEL_METRICS_EXPORTER=otlp` envia pro OTEL Collector (já existe no repo, desabilitado). O collector agrega, transforma, e exporta pro Prometheus. Mais flexível (permite routing de logs/traces), mas adiciona componente.
3. **OTLP direto pro Thanos** — Requer remote-write receiver, não suportado nativamente pelo user workload monitoring.

**Env vars mínimas no ConfigMap do agente:**

```
CLAUDE_CODE_ENABLE_TELEMETRY=1
OTEL_METRICS_EXPORTER=prometheus
# ou para OTLP:
# OTEL_METRICS_EXPORTER=otlp
# OTEL_EXPORTER_OTLP_PROTOCOL=grpc
# OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317
```

**Atributos úteis para multi-agente:**

- `session.id` — correlacionar métricas por sessão
- `user.account_uuid` / `user.email` — identificar quem está usando (resolve a questão "clientes que estão usando" do Sprint A)
- `organization.id` — segmentar por org
- `OTEL_RESOURCE_ATTRIBUTES` — custom labels (`team.id`, `cost_center`, etc.)

**Escopo sugerido:**

- Habilitar `OTEL_METRICS_EXPORTER=prometheus` no pod do agente e criar `PodMonitor`
- Adicionar painéis no Grafana: tokens por agente, custo por sessão, tools mais usadas, erros de API
- Avaliar se logs/events justificam re-habilitar OTEL Collector (opção 2) ou se Prometheus-only é suficiente
- Opcionalmente habilitar traces beta para correlação prompt → tools → LLM calls
- Testar `OTEL_RESOURCE_ATTRIBUTES` com labels de equipe para multi-tenant

**Critérios de saída (exemplo):**

- [ ] Métricas do Claude Code (tokens, custo, sessões) visíveis no Grafana via Prometheus
- [ ] Dashboard de agente com breakdown por sessão/usuário
- [ ] Decisão documentada: Prometheus exporter vs OTLP collector
- [ ] NetworkPolicy e PodMonitor/ServiceMonitor no repo

**Relação com ADR-019:** O OTEL Collector + Prometheus + Grafana do Sprint 2 foram desabilitados porque geravam spans genéricos sem valor vs. MLflow autolog. Esta sprint é diferente: usa as **métricas nativas do Claude Code** (token counts, cost, tool usage), não spans derivados via spanmetrics. Complementa MLflow (traces ricos) com Prometheus (métricas operacionais agregadas).

---

## Nota

**Observability (Sprint A)** responde a *como o modelo/serving (vLLM, GPU, endpoint) se comporta e como depuramos gargalos de inferência*. **Sprint C** responde a *como os agentes consomem recursos (tokens, custo, tempo) e quem está usando*. **MaaS (Sprint B)** responde a *como governamos o acesso aos modelos (API, tiers, quotas)*. Telemetria de **experimentos e traces detalhados** do agente permanece via MLflow conforme ADR-019.
