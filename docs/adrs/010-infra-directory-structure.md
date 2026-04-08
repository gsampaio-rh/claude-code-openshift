# ADR-010: Estrutura de diretorio infra/ para manifests e scripts

**Status:** Accepted
**Date:** 2026-04-08

## Contexto

O repositorio acumulou diretorios top-level para cada componente de infraestrutura: `cluster/`, `agent/`, `inference/vllm/`, `inference/guardrails/`. Isso poluia o root do projeto e misturava infra com docs.

A pasta `inference/` adicionava um nivel de nesting desnecessario — `vllm/` e `guardrails/` sao componentes independentes que nao precisam de um parent comum.

## Decisao

1. Agrupar todos os componentes de infraestrutura sob `infra/`
2. Renomear `agent/` para `claude-code/` (nome mais descritivo)
3. Promover `inference/vllm/` e `inference/guardrails/` para `infra/vllm/` e `infra/guardrails/` (eliminar nesting)

## Estrutura resultante

```
infra/
├── claude-code/     # Agent image, manifests, scripts
├── cluster/         # Operators, namespaces, RBAC, quotas
├── vllm/            # KServe model serving (ServingRuntime, InferenceService)
└── guardrails/      # TrustyAI orchestrator e gateway
```

## Racional

- **Root limpo**: Apenas `docs/` e `infra/` no top-level (alem de config files)
- **Flat > nested**: `infra/vllm/` em vez de `infra/inference/vllm/` — menos nesting, mais direto
- **Nome descritivo**: `claude-code/` em vez de `agent/` — deixa claro qual agente
- **Padrao consistente**: Cada componente tem `manifests/` e `scripts/` internamente

## Consequences

- Scripts usam `PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"` (3 niveis do scripts/ ate root)
- Cross-references entre scripts sao entre siblings: `cd ../vllm` em vez de `cd ../../inference/vllm`
- Docs atualizados com novos caminhos
