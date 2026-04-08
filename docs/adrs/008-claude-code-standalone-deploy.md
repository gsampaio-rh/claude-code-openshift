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
# Pod standalone com Claude Code (ver infra/claude-code/manifests/ para versao completa)
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
    image: quay.io/agentops/claude-code-agent:latest
    envFrom:
    - configMapRef:
        name: claude-code-config
    env:
    - name: ANTHROPIC_API_KEY
      value: "not-needed"
```

Env vars criticas (via ConfigMap `claude-code-config`):
- `ANTHROPIC_BASE_URL` sem `/v1` — vLLM implementa a Anthropic Messages API
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — impede conexoes ao api.anthropic.com
- `ANTHROPIC_AUTH_TOKEN` — obrigatorio (qualquer valor)
- Model name deve ser o `--served-model-name` do vLLM, nao o HuggingFace ID

Refs: [vLLM docs](https://docs.vllm.ai/en/latest/serving/integrations/claude_code/), [Issue #36998](https://github.com/anthropics/claude-code/issues/36998)

Na Fase 1, aponta direto pro vLLM (sem Guardrails, que so vem na Fase 2). Na Fase 2+, muda `ANTHROPIC_BASE_URL` pra Guardrails gateway endpoint.

## Dois modos de operacao

| Modo | Surface | Use case | Disponivel em |
|---|---|---|---|
| **Standalone** | Pod com `claude --headless` ou `oc exec -it` | Validacao, automacao, CI/CD, batch | Fase 1 |
| **CDE-embedded** | Coder workspace template | Dev interativo via VS Code/terminal | Fase 3 |

## Trade-offs

- **Pod adicional a manter**: mais um deployment. Mitigacao: eh um pod simples com imagem UBI + Claude Code, sem state.
- **Env vars duplicadas**: standalone e Coder template tem env vars similares. Mitigacao: ConfigMap compartilhado.
- **Sem UI na Fase 1**: dev interage via `oc exec` ou port-forward. Mitigacao: temporario — Coder chega na Fase 3.

## Consequences

- Fase 1 do PRD inclui deploy e validacao do Claude Code standalone
- Container image base (UBI9 nodejs-22 + Claude Code CLI) buildada via `infra/claude-code/scripts/build-image.sh`
- ConfigMap com env vars do agente criado no namespace `agent-sandboxes` (reusavel pelo Coder)
- Criterio de aceitacao novo: Claude Code responde com modelo local antes do Coder existir
- Arquitetura ganha uma "Agent Layer" explicita, separada da CDE Layer
