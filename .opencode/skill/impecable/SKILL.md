---
name: impecable
description: Acabamento visual e de interação "impecável" para apps móveis. Zero elementos genéricos, hierarquia clara, estados completos (vazio/carregando/erro/sucesso), consistência entre telas, feedback em todo toque, e polimento de detalhes (sombras, raios, espaçamento, tipografia). Companheiro do design-apple e design-ui para entregar layout de qualidade de produto.
---

# impecable

Checklist de acabamento para cada tela, aplicado após o design-ui. Uma tela só está "impecável" quando todos os itens abaixo passam.

## 1. Nenhum elemento genérico
- Sem `Container` branco solto sobre mapa ou fundo escuro; todo card usa `surface` do tema + borda + sombra.
- Sem texto sem estilo (`Text('...')` sem `style`); tudo passa por `bodyStyle/titleStyle/labelStyle` ou `AppType`.
- Sem ícones soltos sem `Semantics`/`Tooltip` quando interativo.
- Sem `SizedBox` aleatório de espaçamento; usar `AppSpace.xs/s/m/l/xl/xxl`.

## 2. Hierarquia visual
- Título da tela: 20–26 dp, peso w600+, cor `ink` do tema.
- Corpo: 14–16 dp, cor `ink` ou `muted` conforme importância.
- Legenda/auxiliar: 11–12 dp, cor `muted`.
- CTA primário: teal `primary`, 48 dp, texto w600 16 dp, glow opcional.
- CTA secundário: `OutlinedButton`, borda `hairline`, texto `ink`.

## 3. Estados completos (tela que mostra dados)
- **Vazio:** ícone 64 dp + título + 1 frase + ação primária visível.
- **Carregando:** indicador visível + conteúdo de fundo com opacidade ~0.6.
- **Erro:** cor `danger`, ícone `error_outline`, mensagem 1 linha, botão "Tentar novamente".
- **Sucesso:** feedback visual (check teal) + próximo passo claro.

## 4. Feedback em todo toque
- Todo botão tem estado pressed/disabled visível (`Opacity 0.55` ou mudança de cor).
- `InkWell`/`Material` com `borderRadius` consistente (mínimo `radiusCard`).
- Tooltips em ícones de ação sem rótulo texto.

## 5. Polimento de detalhes
- Sombra apenas em elementos flutuantes (cards, sheets, FAB); nunca em elementos colados na borda.
- Raio consistente: `radiusCard=12` para cards, `radiusSheet=18` para bottom sheets, `radiusChip=999` para pills/chips.
- Inputs: fill `surface`, borda `hairline`, raio `radiusCard`, label + hint legíveis.
- SafeArea em toda tela; reserve `padding.bottom` para gestos do Android.
- Teclado não cobre inputs (use `SingleChildScrollView` ou `resizeToAvoidBottomInset`).

## 6. Consistência passageiro × parceiro
- Mesmo componente = mesmo nome, mesma assinatura, mesmo comportamento nos dois apps.
- Cores, raios e espaçamentos idênticos em ambos os temas (claro/escuro).

## Como usar com fable-method
- Step 2: rode este checklist em cada tela alvo; anote falhas com arquivo:linha.
- Step 4: corrija um item por vez, menor mudança possível.
- Step 5: re-rodo o checklist; item antes falho deve passar.
