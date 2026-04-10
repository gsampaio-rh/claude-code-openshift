# Future explorations — backlog de sprints

**Status:** Backlog  
**Data:** 2026-04-10  
**Relacionado:** [PLAN.md](PLAN.md) | [ADR-019 — Observability](adrs/019-observability-otel-mlflow-grafana.md)

Dois temas que ficam **fora do núcleo imediato do PoC**, mas merecem tempo dedicado: **observabilidade do modelo em execução** (vLLM / serving / GPU) e **Models-as-a-Service** (governança de acesso ao LLM no OpenShift AI). Cada bloco abaixo pode virar uma sprint de exploração quando houver capacidade.

---

## Sprint A — Observability do modelo (vLLM / inferência)

**Objetivo:** Medir e visualizar o **runtime de inferência** — filas, latência, throughput de tokens, utilização de GPU, saúde do endpoint — **não** a telemetria do agente (Claude Code) nem experimentos no MLflow. Isso é outra linha de trabalho; ver [ADR-019](adrs/019-observability-otel-mlflow-grafana.md) apenas se cruzar com stack compartilhada (Grafana/Prometheus).

**Contexto:** O vLLM expõe métricas Prometheus no processo de serving. No OpenShift, o padrão é **user workload monitoring**: `PodMonitor` / `ServiceMonitor` para o Prometheus do cluster scrapear o endpoint de métricas do deployment de inferência; opcionalmente **DCGM** (ou equivalente) para métricas de GPU; dashboards tipo **vLLM** e cluster/GPU. Referência de arquitetura alinhada à prática Red Hat: [redhat-et/ai-observability — rhoai](https://github.com/redhat-et/ai-observability/tree/main/rhoai).

**Escopo sugerido:**

- Garantir **scrape** das métricas do vLLM (namespace de inferência, labels corretos, rota interna ao metrics port).
- Opcional: **OpenTelemetry** só na medida em que fizer sentido para **traces/métricas do caminho de inferência** ou export unificado — não como substituto das métricas nativas do vLLM.
- **Dashboards** focados em serving (ex.: fila de requisições, tokens/s, latência por etapa, erros HTTP, pressão de KV cache quando exposto) e, se aplicável, painéis de **GPU**.
- **Runbooks** curtos: “serving lento” vs. “GPU saturada” vs. “endpoint não scrapeado”.

**Critérios de saída (exemplo):**

- [ ] Métricas do vLLM visíveis no backend de séries (Console Observe / Grafana / Prometheus) no ambiente de referência.
- [ ] Pelo menos um dashboard de **inferência** (não de agente) validado sob carga de teste.
- [ ] Manifests ou notas no repo (ex. `observability/` ou `infra/`) para reproduzir o scrape e o dashboard.

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
