# ADR-009: UBI base image para agente Claude Code

**Status:** Accepted
**Date:** 2026-04-08

## Contexto

A imagem do agente Claude Code precisa de Node.js (runtime do CLI) e git (operacoes de repositorio). Opcoes avaliadas:

- `node:22-slim` (community, Debian-based)
- `registry.access.redhat.com/ubi9/nodejs-22` (Red Hat UBI)

## Decisao

Usar `registry.access.redhat.com/ubi9/nodejs-22` como base image.

## Racional

1. **Compatibilidade OpenShift**: UBI images rodam com UIDs arbitrarios (OpenShift atribui UIDs aleatoriamente via Security Context Constraints). O user 1001 default da UBI funciona sem `useradd` customizado.
2. **Pod Security Standards**: UBI images ja sao compatíveis com `restricted` profile sem ajustes.
3. **Suporte Red Hat**: Imagens UBI tem CVE tracking e patches oficiais.
4. **curl/ca-certificates inclusos**: UBI nodejs-22 ja inclui curl e certificados, reduzindo layers no Dockerfile.

## Alternativas descartadas

- `node:22-slim`: Funciona, mas requer `useradd`, nao tem suporte Red Hat, e pode ter problemas com UID arbitrario no OpenShift.
- `ubi9/nodejs-22-minimal`: Mais leve, mas falta `dnf` para instalar git. Requer `microdnf` com sintaxe diferente.

## Consequences

- Dockerfile em `agents/claude-code/Dockerfile` usa UBI como base
- Claude Code CLI instalado via `curl -fsSL https://claude.ai/install.sh | bash` (metodo oficial, binario em `~/.local/bin`)
- `npm install -g @anthropic-ai/claude-code` nao eh mais o metodo recomendado pela Anthropic

## Refs

- https://developers.redhat.com/articles/2026/03/26/integrate-claude-code-red-hat-ai-inference-server-openshift
- https://github.com/anthropics/claude-code/pull/27306
