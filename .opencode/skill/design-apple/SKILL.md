---
name: design-apple
description: Princípios do Apple Design (Human Interface Guidelines) aplicados a apps móveis: clareza, deferência, profundidade, tipografia, ícones, modos claro/escuro, feedback tátil e layout responsivo. Útil para avaliar se um layout está "implacável" (polido, com personalidade, não genérico).
---

# design-apple

Princípios da Apple (Human Interface Guidelines) traduzidos para auditoria e construção de layouts móveis (Flutter). Use antes de editar qualquer tela e depois para verificar o resultado.

## Os três temas da Apple

1. **Clareza** — o texto é legível em qualquer tamanho; ícones são reconhecíveis; o foco está no conteúdo, não na decoração.
2. **Deferência** — o UI ajuda, não compete: bordas sutis, cores de suporte, mapas/fotos de fundo sem poluição; a marca aparece, mas não grita.
3. **Profundidade** — camadas visíveis (overlays, sheets, cards) com sombras e transições claras; o usuário sempre sabe onde está e para onde pode ir.

## Checklist prático (aplique em cada tela)

| Item | O que verificar | Passe se |
|------|----------------|----------|
| Tipografia | Hierarquia clara: título (20–26), corpo (14–16), legenda (11–12); nunca texto abaixo de 11 dp | ler no emulador sem esforço |
| Espaçamento | Grade 4 dp; botões/inputs ≥ 48 dp de altura; margem lateral ≥ 16 dp | nada encosta na borda |
| Cores | Contraste WCAG AA (≥4,5:1 texto normal, ≥3:1 grande) em claro e escuro | medir com ferramenta de contraste |
| Modo escuro | Não é só inverter: superfícies escuras (#0F172A), textos quase-brancos (#F8FAFC), bordas sutis (#334155) | ler confortável no escuro |
| Botões primários | Teal #05998C, preenchido, mínimo 48 dp, estado pressionado visível | chama a ação certa |
| Feedback | Toque muda opacidade/elevação; loading mostra estado; erros têm cor e mensagem | nunca deixa dúvida se clicou |
| Navegação | Voltar visível e consistente; abas/rótulos com ícone + texto; deep links funcionam | nunca fica preso em uma tela |
| Imagens | Logo com fundo adequado ao fundo da tela; fallback de texto se a imagem não carregar | não fica retângulo branco solto |

## Regras de marca (10 é +, teal #05998C)

- Teal só em CTA primário, links, marcador de marca e ícones de ação. Nunca em texto de corpo ou erro.
- "+" isolado só com a palavra "10 é +"; nunca sozinho como ícone genérico.
- Texto sobre teal: branco ou #12211F (contraste ≥4,5:1).
- Fundo da marca (claro): #F2F8F7; superfície: #FBFEFD; escuro: #020617 / #0F172A.

## Como usar com fable-method

- Step 2 (evidência): rode este checklist na tela alvo; anote cada item que falha com arquivo:linha.
- Step 4 (ação): corrija apenas o que falhou, um item por vez.
- Step 5 (verificação): re-rodo o checklist na mesma tela; o item antes falho deve passar agora.
