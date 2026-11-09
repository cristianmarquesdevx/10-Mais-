---
name: memory
description: Memória persistente do projeto 10 é + entre sessões. Use no início de qualquer trabalho neste repositório para recuperar decisões, estado e pendências, e ao final para registrar o que mudou e o que foi verificado. Também atende "/memory", "o que ficou pendente?", "lembra da última sessão?" e "salva isso na memória".
---

# memory

Agentes esquecem entre sessões e repetem erros caros: restauram código já corrigido, refazem decisões, ou declaram pronto o que nunca foi testado. Esta skill dá ao OpenCode uma memória durável e barata: um arquivo por projeto, lido antes e escrito depois.

## Onde fica

`.opencode/memory/MEMORY.md` na raiz do projeto.

Formato fixo (não invente seções):

```markdown
# Memória do projeto

## Estado atual
- ...

## Decisões
- AAAA-MM-DD — decisão — motivo

## Pendências
- [ ] ...

## Histórico
- AAAA-MM-DD — o que mudou — como foi verificado
```

## Rotina obrigatória

1. **Antes de agir** (qualquer tarefa não trivial neste repo): rode
   `python .opencode/skill/memory/memory.py show`
   e leia o arquivo inteiro. Se a tarefa contradiz uma decisão registrada, pare e confirme com o usuário — decisão registrada vence memória curta do modelo.
2. **Durante**: quando descobrir um fato durável (endpoint, comando, credencial de teste sem segredo, armadilha de ambiente), registre na hora com `add`, sem esperar o fim.
3. **Ao terminar**: rode `add` com uma linha objetiva:
   `AAAA-MM-DD — <o que mudou> — <como foi verificado>`.
   Só entra o que foi observado; "deve funcionar" não é verificação.
4. **Pendências**: atualize a seção `## Pendências` (edite o arquivo) quando algo ficar em aberto; remova quando concluído.

## Comandos

```bash
python .opencode/skill/memory/memory.py show
python .opencode/skill/memory/memory.py add "2026-11-01 — tema teal restaurado — git diff vazio + testes 35/34"
python .opencode/skill/memory/memory.py search "teal"
python .opencode/skill/memory/memory.py prune 40      # mantém só as 40 entradas mais recentes do Histórico
```

## Limites (não negociáveis)

- **Nunca** grave segredos, tokens, senhas ou chaves. Tokens de teste ficam em `%TEMP%\opencode`, não aqui.
- Memória é resumo, não diário: uma linha por evento, sem despejo de logs.
- Se o arquivo passar de ~200 linhas, rode `prune` e mova o excedente para `.opencode/memory/archive/AAAA.md`.
- Memória não substitui evidência: antes de repetir uma afirmação da memória, confira se ainda é verdade (git, teste, arquivo).

## Integração com fable-method

No Step 2 (evidência), a memória é ponto de partida, nunca prova: fatos antigos precisam de re-checagem. No Step 6 (relatório), toda decisão durável nova vira uma entrada em `## Decisões`.
