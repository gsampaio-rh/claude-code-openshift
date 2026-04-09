# ADR-016: GPU Scaling — L4 24GB to L40S 48GB

**Status:** Accepted
**Data:** 2026-04-08
**Relacionado:** ADR-002, ADR-011, ADR-014

## Contexto

Sprint 1 rodou vLLM com Qwen 2.5 14B no NVIDIA L4 (24GB VRAM). Limitacoes:

1. `max_model_len=24576` — modelo suporta 32768 nativamente, mas KV cache nao cabia no L4
2. `CLAUDE_CODE_MAX_OUTPUT_TOKENS=2048` — limitado pra caber no context de 24K
3. `--enforce-eager` obrigatorio — GPU memory pressure com 95% utilization
4. `--gpu-memory-utilization=0.95` — sem margem pra CUDA graphs ou batching
5. Latencia alta em prompts complexos (~101s pra classe com 500 tokens output)

System prompt do Claude Code consome ~12K tokens (fixo, nao controlavel). Com L4:
- 24K context = 12K system + 10K input + 2K output (muito limitado)
- Sem espaco pra multi-file context ou respostas longas

## Decisao

Escalar de NVIDIA L4 (g6.4xlarge, 24GB VRAM) para NVIDIA L40S (g6e.4xlarge, 48GB VRAM).

## Racional

| Criterio | L4 24GB | L40S 48GB |
|---|---|---|
| VRAM | 24 GB | 48 GB |
| `max_model_len` | 24,576 (limitado) | 32,768 (maximo nativo do Qwen 2.5 14B) |
| `max_output_tokens` | 2,048 | 16,384 |
| `enforce-eager` | Sim (memory pressure) | Nao (CUDA graphs + torch.compile) |
| `gpu-memory-utilization` | 0.95 | 0.90 (margem confortavel) |
| Modelo em memoria | ~15 GB (~63% VRAM) | ~15 GB (~32% VRAM) |
| KV cache disponivel | ~8 GB | ~28 GB |
| Custo AWS (on-demand) | $1.32/h (g6.4xlarge) | $1.86/h (g6e.4xlarge) |

Qwen 2.5 14B tem `max_position_embeddings=32768`. O valor 131072 (que aparece em docs do Qwen) se aplica apenas a modelos maiores (72B) com YaRN scaling.

## Alternativas descartadas

1. **FP8 quantization (manter L4)**: Modelo ja eh FP8-dynamic. Nao ha mais quantizacao a ganhar.
2. **A10G (g5.4xlarge, 24GB)**: Mesma VRAM do L4, sem ganho.
3. **A100 (p4d, 40/80GB)**: Muito caro ($3.09-$32.77/h), overkill pra 14B.
4. **H100 (p5, 80GB)**: Disponibilidade limitada e custo ($5.12+/h).
5. **Reduzir model_len (manter L4)**: 24K nao eh suficiente pra prompts reais com Claude Code system prompt.

## Implementacao

1. Criado MachineSet `gpu-l40s-us-east-2b` (g6e.4xlarge, 1x L40S)
2. Node labels: `node-role.kubernetes.io/gpu`, `nvidia.com/gpu.product: NVIDIA-L40S`
3. Taints: `nvidia.com/gpu=true:NoSchedule`
4. Deployment atualizado com `nodeSelector` + `tolerations` para L40S
5. Strategy mudada de RollingUpdate para `Recreate` (PVC RWO nao suporta multi-attach cross-node)
6. ResourceQuota `inference-quota` aumentada: memory 64Gi → 128Gi, cpu 16 → 32

## Configuracao vLLM na L40S

```yaml
args:
  - --max-model-len=32768       # Maximo nativo do Qwen 2.5 14B
  - --gpu-memory-utilization=0.90
  - --enable-chunked-prefill    # Reduz memory spikes em system prompts grandes
  - --tool-call-parser=hermes
  - --enable-auto-tool-choice
resources:
  limits:
    memory: 48Gi
    nvidia.com/gpu: "1"
```

Nota: `--enforce-eager` removido — L40S tem VRAM suficiente para CUDA graphs + torch.compile.

## Consequencias

**Positivas:**
- Context window completo do modelo (32K) disponivel
- Output tokens escalado de 2K para 16K (respostas longas, multi-file)
- CUDA graphs + torch.compile ativados (melhor throughput)
- Margem de 10% VRAM livre para overhead e batching futuro
- Latencia reduzida em prompts complexos

**Negativas:**
- Custo ~41% maior ($1.86/h vs $1.32/h)
- Node L4 existente fica ocioso (pode ser terminado ou reutilizado)
- Deployment strategy `Recreate` causa downtime breve durante rollout (PVC RWO)

**Riscos:**
- L40S pode nao estar disponivel em todas as AZs (mitigacao: AZ especifica no MachineSet)
