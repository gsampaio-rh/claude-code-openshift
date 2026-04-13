# ADR-010: Repository directory structure

**Status:** Superseded (updated 2026-04-13)
**Date:** 2026-04-08

## Contexto

Originalmente, todos os componentes viviam sob `infra/` (cluster, vllm, claude-code, guardrails, scripts). Com o crescimento do projeto, a separacao por concern ficou mais clara: agents, inference, guardrails e infra de cluster sao preocupacoes distintas.

## Decisao

Separar os componentes em diretorios top-level por concern:

1. `agents/` — agentes (Claude Code)
2. `inference/` — model serving (vLLM)
3. `guardrails/` — safety (TrustyAI)
4. `infra/` — apenas recursos de cluster (operators, namespaces, RBAC, quotas, Kata)
5. `observability/` — stack de observabilidade (MLflow, OTEL, Grafana, dashboards)
6. `scripts/` — orchestracao (deploy-all.sh, e2e-test.sh)

## Estrutura resultante

```
├── agents/claude-code/   # Agent image, manifests, scripts
├── inference/vllm/       # vLLM deployment manifests and scripts
├── guardrails/           # TrustyAI orchestrator
├── infra/cluster/        # Operators, namespaces, RBAC, quotas, Kata
├── observability/        # MLflow, OTEL, Grafana, dashboards
├── scripts/              # deploy-all.sh, e2e-test.sh
└── docs/                 # Architecture, ADRs
```

## Racional

- **Separation of concerns**: Cada diretorio top-level representa uma preocupacao distinta
- **Navegacao intuitiva**: Encontrar componentes sem precisar lembrar que tudo vivia sob `infra/`
- **Padrao consistente**: Cada componente mantem `manifests/` e `scripts/` internamente

## Consequences

- Scripts de orchestracao (`scripts/deploy-all.sh`) usam paths absolutos a partir de `PROJECT_ROOT`
- Cross-references entre componentes usam caminhos relativos ao root do projeto
- Docs atualizados com novos caminhos
