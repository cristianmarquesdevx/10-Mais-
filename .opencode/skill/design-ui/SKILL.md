---
name: design-ui
description: Princípios de UI front-end para apps móveis: sistema de espaçamento, grade 8dp, toque 48dp, contraste WCAG, componentes base (botão, input, card, sheet, toast), estados (vazio, carregando, erro) e consistência entre telas. Companheiro do design-apple para entrega de layout "implacável".
---

# design-ui

Sistema de UI genérico (compatível com Material 3 e com o tema teal existente em `app/*/lib/src/theme/theme.dart`). Não adiciona dependências — só organiza o que já existe.

## Token base (já no projeto)

Usar estes, nunca valores mágicos:

- Espaço: `AppSpace.xs=4, s=8, m=12, l=16, xl=24, xxl=32`
- Raio: `radiusCard=12, radiusSheet=18, radiusChip/radiusPill=999`
- Alvo de toque: `target=48` dp
- Cores: `AppColors.primary` (teal #05998C), `ink`, `muted`, `surface`, `background`, `danger`, `warning`, `hairline`
- Texto: `AppType.display/title/body/label/money/countdown`, sempre via `bodyStyle/titleStyle/labelStyle` (cor vem do tema)

## Componentes-base que toda tela deve ter

1. **CTA primário** — `GradientButton` (já existe), teal, 48 dp, texto w600 16 dp, estado disabled com opacidade 0.55.
2. **OutlinedButton secundário** — borda `hairline`, texto `ink`, 48 dp.
3. **Input** — `InputDecorationTheme` já definido (fill `surface`, borda `hairline`, raio `radiusCard`); label + hint nunca abaixo de 14 dp.
4. **Card/Sheet** — `surface` do tema, borda fina, raio `radiusSheet`, sombra `appShadow` (claro) / `appShadowDark` (escuro).
5. **Estado vazio** — ícone grande (64 dp) + título + 1 linha de explicação + ação primária; nunca tela branca sem nada.
6. **Estado erro** — cor `danger`, ícone `error_outline`, mensagem em 1 linha, botão "Tentar novamente".
7. **Loading** — `CircularProgressIndicator` sobre o conteúdo ou skeleton; nunca botão sumindo sem aviso.

## Regras de layout (360 × 800 dp, alvo principal)

- Coluna única com `CrossAxisAlignment.stretch`; não use `FixedExtent` ou larguras fixas acima de 280 dp.
- SafeArea sempre; reserve `MediaQuery.padding.bottom` para a navegação por gestos do Android.
- Teclado aberto: inputs de login/cadastro não podem ficar cobertos pelo teclado (`SingleChildScrollView` ou `resizeToAvoidBottomInset`).
- Fonte grande (acessibilidade): evite `fixed height` em containers de texto; use `Expanded`/`Flexible` e `mainAxisSize: min`.

## Estados que não podem faltar em cada fluxo

| Estado | Mínimo obrigatório |
|--------|-------------------|
| Vazio | ícone + título + 1 frase + botão de ação |
| Carregando | indicador visível + opacidade 0.6 no conteúdo de fundo |
| Erro | cor danger + mensagem legível + botão recuperar |
| Sucesso | feedback visual (check teal) + opção de próximo passo |

## Consistência passageiro × parceiro

Mesmo componente deve ter o mesmo nome, mesma assinatura e mesmo comportamento nos dois apps. Se criar um widget novo no parceiro (ex.: `SupportFab`), espelhe no passageiro se fizer sentido para o fluxo correspondente.

## Como usar com fable-method

- Step 2: percorra cada tela dos dois apps com este checklist; registre falhas em arquivo:linha.
- Step 4: edite o menor número de arquivos possível; prefira ajustar `theme.dart` + a tela específica a criar componentes novos.
- Step 5: rode `dart analyze lib test` e os testes de fluxo dos dois apps antes de encerrar.
