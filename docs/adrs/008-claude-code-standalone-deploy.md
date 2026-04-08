# ADR-008: Claude Code Standalone Deployment

**Status:** Accepted
**Date:** 2026-04-08
**Deciders:** Platform Engineering

## Context

No design original, Claude Code era deployado exclusivamente dentro de workspace templates do Coder. Isso significava que a validacao do core da plataforma — agente conversando com modelo local — so acontecia apos montar toda a stack do CDE (Coder + PostgreSQL + OAuth + Terraform templates), na semana 2-3.

Problemas com essa abordagem:

1. **Feedback loop lento**: se o Qwen 2.5 14B nao funciona bem com Claude Code, so descobrimos depois de dias de setup do Coder
2. **Acoplamento desnecessario**: Claude Code eh um CLI Node.js que precisa apenas de env vars pra funcionar — nao depende do Coder
3. **Sem path pra automacao**: Claude Code headless pode rodar tarefas em CI/CD, batch jobs, ou como agent autonomo — mas se esta preso ao Coder, esse use case nao existe
4. **Risco composto**: um problema no Coder (SCC, OAuth, Terraform) bloqueia a validacao do agente

## Decision

Deploy **Claude Code como pod standalone** no namespace `agent-sandboxes`, independente do Coder, na Fase 1 (junto com vLLM).

O Coder continua existindo como camada de UX para devs (Fase 3), mas o agente roda e eh validado antes.

## Rationale

- **Fail fast**: valida compatibilidade Claude Code ↔ vLLM/Qwen na semana 1, antes de qualquer outra dependencia
- **Separacao de concerns**: agente (Claude Code) e CDE (Coder) sao componentes independentes que podem evoluir separadamente
- **Headless mode nativo**: Claude Code suporta `--headless` e API mode (porta 3000+), perfeito pra rodar como pod standalone
- **Reuso**: o mesmo pod/imagem pode ser usado em Coder templates (Sprint 2), pipelines Tekton (Sprint 5), ou automacoes futuras
- **Principio BYOA**: a plataforma nao deve assumir que o agente precisa de um CDE — deve funcionar com qualquer surface (terminal, IDE, headless)

## Deployment

```yaml
# Pod standalone com Claude Code
apiVersion: v1
kind: Pod
metadata:
  name: claude-code-standalone
  namespace: agent-sandboxes
  labels:
    app: claude-code
    kagenti.io/type: agent
spec:
  containers:
  - name: claude-code
    image: node:20-slim
    command: ["sleep", "infinity"]
    env:
    - name: ANTHROPIC_BASE_URL
      value: "http://vllm.inference.svc:8000/v1"
    - name: ANTHROPIC_API_KEY
      value: "sk-placeholder"
    - name: ANTHROPIC_DEFAULT_SONNET_MODEL
      value: "Qwen/Qwen2.5-14B-Instruct"
    - name: CLAUDE_CODE_MAX_OUTPUT_TOKENS
      value: "4096"
    - name: MAX_THINKING_TOKENS
      value: "0"
```

Na Fase 1, aponta direto pro vLLM (sem Guardrails, que so vem na Fase 2). Na Fase 2+, muda `ANTHROPIC_BASE_URL` pra Guardrails endpoint.

## Dois modos de operacao

| Modo | Surface | Use case | Disponivel em |
|---|---|---|---|
| **Standalone** | Pod com `claude --headless` ou `oc exec -it` | Validacao, automacao, CI/CD, batch | Fase 1 |
| **CDE-embedded** | Coder workspace template | Dev interativo via VS Code/terminal | Fase 3 |

## Trade-offs

- **Pod adicional a manter**: mais um deployment. Mitigacao: eh um pod simples com Node.js + npm, sem state.
- **Env vars duplicadas**: standalone e Coder template tem env vars similares. Mitigacao: ConfigMap compartilhado.
- **Sem UI na Fase 1**: dev interage via `oc exec` ou port-forward. Mitigacao: temporario — Coder chega na Fase 3.

## Consequences

- Fase 1 do PRD inclui deploy e validacao do Claude Code standalone
- Container image base (`node:20-slim` + `claude` CLI) precisa ser definida e testada
- ConfigMap com env vars do agente criado no namespace `agent-sandboxes` (reusavel pelo Coder)
- Criterio de aceitacao novo: Claude Code responde com modelo local antes do Coder existir
- Arquitetura ganha uma "Agent Layer" explicita, separada da CDE Layer
