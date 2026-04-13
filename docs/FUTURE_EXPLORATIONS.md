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

## Nota

**Observability (Sprint A)** responde a *como o modelo/serving (vLLM, GPU, endpoint) se comporta e como depuramos gargalos de inferência*. **MaaS (Sprint B)** responde a *como governamos o acesso aos modelos (API, tiers, quotas)*. Telemetria do **agente** (experimentos, traces de ferramentas) é um eixo à parte, coberto no PoC sobretudo via MLflow conforme ADR-019.
