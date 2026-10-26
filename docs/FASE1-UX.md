# Fase 1 — Produto e UX/UI — "10 é +"

> Arquivo de trabalho da Fase 1. Consolida as partes 1..4 entregues; o GATE 1 é do usuário.
> Status: Parte 1 entregue; Parte 2 entregue (ver consolidação na Parte 4).

---

# PARTE 1/4 — Guia de marca + Design system + Princípios

## 1. Guia de marca "10 é +"

### 1.1 Identidade verbal

| Item | Definição |
|---|---|
| Nome | **10 é +** (leitura: "dez é mais") |
| Slug técnico | `dezemais` (applicationId `br.dezemais.client` / `br.dezemais.partner`) |
| Loja | "10 é + Passageiro" · "10 é + Parceiro" · domínio `dezemais.app` [VERIFICAR disponibilidade] |
| Promessa ao parceiro | "Você ganha mais" — PASSE = 100% seu |
| Promessa ao cliente | "Nota 10 de verdade" — preço justo e segurança |
| Tom de voz | **Próximo, direto, local.** Frases curtas, verbo no início, sem juridiquês. |

Do / Don't: ✅ "Seu passe vence em 1 h. Renove em 1 toque." ✅ "Cancelou 2 vezes esta semana — mais 3 e dá uma pausa de 12 h." ❌ "Sua solicitação não pôde ser processada com sucesso."

### 1.2 Logotipo e ícone

- **Assinatura:** `10 é+` — "+" encostado no "é", em verde (destaque). Versões: horizontal, ícone isolado, monocromática.
- **Ícone 48 px:** "10+" em Black, "+" como sobrescrito (~40% da altura) no canto do zero. Sem gradientes; fundo sólido primário, glifos em branco. Aceite: legível em mono 48×48 e no ícone 512 px da Play.
- **Regra do "+":** nunca isolado; verde quando positivo; nunca para erro/alerta.

### 1.3 Paleta (contraste WCAG 2.1 calculado)

| Token | Hex | Uso | Contraste |
|---|---|---|---|
| `color-primary` | `#0066FF` | CTA principal, links, marcador usuário | 4,8:1 vs branco |
| `color-primary-dark` | `#0052CC` | pressed / ativo | > 6:1 vs branco |
| `color-earn` | `#0A7F45` | ganho parceiro, passe ativo, "+", confirmação | 5,1:1 vs branco |
| `color-warning` | `#9E5D00` | passe vencendo, saldo baixo, dívida | 5,2:1 vs branco |
| `color-danger` | `#C62828` | erro, SOS, bloqueio | 6,0:1 vs branco |
| `color-ink` | `#0F172A` | texto principal (claro) | ~17:1 |
| `color-muted` | `#475569` | texto secundário | ~7,9:1 |
| `color-hairline` | `#94A3B8` | só borda/decorativo (nunca texto) | 2,8:1 |
| `color-surface` / `bg` | `#FFFFFF` / `#F8FAFC` | superfície / fundo claro | — |
| Escuro: `bg #0F172A`, `surface #1E293B`, `text #F8FAFC`, `primary #3B82F6` | | | primary 4,8:1 vs bg escuro |

Por que azul + verde: azul = confiança/segurança (maior objeção da categoria); verde = dinheiro e "+". Descartados: laranja/vermelho (conota alerta) e roxo (fraco em ícone 48 px).

### 1.4 Tipografia, espaçamento, superfície

| Token | Valor |
|---|---|
| Fonte | Sistema (Roboto/SF) — zero bundle, escala do usuário nativa |
| Escala | 1,25×: 12/14/16(base)/20/25/31/39 dp; dinheiro e cronômetro em `display` tabular |
| Espaçamento | grade 4 dp (4/8/12/16/24/32) |
| Raios | 8 (cards) / 12 (sheet) / 999 (chips) |
| Elevação | 3 níveis: sheet > card > hairline |
| Ícones | Material Symbols (open source), peso 400–600 |

### 1.5 Componentes-chave

`Button` (48 dp; primary/earn/ghost/danger) · `OfferCard` (hierarquia: valor bruto 31 dp > distância coleta > total > destino aproximado ≈ R$/h > cronômetro 15 s) · `PassCard` (saldo, contagem regressiva, renovação 1 toque) · `BottomSheet` (pagamento/cancelamento/emergência) · `RideTimeline` (estado atual + próximo passo) · `CameraGuide` (KYC/fotos, overlay de enquadramento) · `ChatBubble` + anexo · `Banner` offline. Todo componente: default/pressed/disabled/loading; containers: vazio/erro/offline.

### 1.6 Acessibilidade

Alvos ≥ 48 dp · AA (tabela) · nunca cor sozinha · reduzir movimento (< 200 ms ou nada) · TalkBack com labels pt-BR, cronômetro anunciado a cada 10 s · fonte do sistema até 200% sem quebrar · dinheiro sempre R$ 2 casas.

## 2. Princípios de uso

1. Uma mão, sob sol: CTA no terço inferior; sem translucidez sobre mapa.
2. Solicitar em ≤ 3 toques (destino → pagamento pré-selecionado → "Chamar"); negociação é opcional.
3. Oferta legível em ≤ 3 s (valor bruto maior elemento; R$/h visível).
4. Parceiro lê pouco: ações grandes, ícone + 1 palavra; só "iniciar corrida" usa deslize.
5. Rede ruim é estado normal: faixa offline, fila local visível, nada trava.

---

# PARTE 2/4 — Mapa de navegação + fluxos (consolidado)

## Modelo global de estados

| Dimensão | Estados | Comportamento |
|---|---|---|
| Conectividade | ONLINE · DEGRADADO · OFFLINE | Banner fixo; offline = somente leitura + fila de posição do parceiro; proibidos: pedido, compra, cancelamento (ADX-UX-3) |
| Localização negada | fg · bg | fg: busca manual + pin; bg (parceiro): bloqueia ficar online + guia |
| Notificações negadas | — | Aviso: alarmes/ofertas podem não aparecer |
| Câmera negada | — | Bloqueia KYC/fotos + guia |
| Conta | NORMAL · EM_ANALISE · BLOQUEADO_(cancelamentos\|kyc\|suporte) | Countdown + motivo |

## Máquina da corrida (D1)

CRIADA → BUSCANDO → [PROPOSTA ↔ CONTRAPROPOSTA (opcional)] → OFERTADA → ACEITA (timeout 15 s → EXPIRADA + reoferta) → A_CAMINHO → CHEGOU (raio 50 m) → EM_VIAGEM → FINALIZADA → (FALHA_PAGAMENTO ↔ FINALIZADA, retry idempotente). CANCELADA_(cliente\|parceiro\|sistema\|suporte) a partir dos estados pré-aceite/aceite conforme regras do F7. ENTREGA (MVP-B): FOTOS_PENDENTES → COLETA_CONFIRMADA → EM_ROTA → FINALIZADA; EM_ROTA → TENTATIVA_FALHA → DEVOLUCAO. Guardas: transição só por função de domínio; evento imutável por transição (actor, reason, idempotency_key, occurred_at, received_at).

## Garantias por fluxo (F1..F9)

| Fluxo | Garantias de estado (resumo da entrega) |
|---|---|
| F1 Onboarding | OTP: cooldown 60 s após 3 erros; 1ª entrada exige rede; permissões com 3 saídas; LGPD por finalidade |
| F2 Solicitar | vazio=recentes; offline=sem preço/sem Chamar; erro preço=retry+negociar; negociação com piso, contraproposta e anti-colusão |
| F3 Oferta | offline=não recebe; hierarquia 3 s; expira→reoferta; 3 expiradas→soft-offline |
| F4 Ciclo | GPS fraco=ETA do servidor; no-show 5 min (PRM); PSP cai=cobrança em fila idempotente; rota curta não cobra |
| F5 Passe | ativação agendada; falha→COMISSÃO; avisos 60/15/0; vence em corrida→snapshot imutável; nunca bloqueia |
| F6 Pagamentos | PIX: QR+expiração+webhook; dinheiro: declaração+divergência→ticket+dívida bloqueia só dinheiro; cartão: hosted+recusa+3DS; pendência libera novo pedido até R$ 30 (PRM) |
| F7 Cancelamento | sem-falta vs falta; 5 faltas/7d móvel→12 h countdown; contestação in-app; offline=não cancela |
| F8 SOS | 1 toque; suporte SLA 2 min com contexto; link público expirável; offline→192/190+SMS |
| F9 KYC | captura guiada (borrão/reflexo); 3 faixas de decisão; reenvio só do doc problemático; em análise=não online |

Microcopy pt-BR: catálogo completo na Parte 3 (seção D) — strings de vazio, erro, offline, permissão, financeiro, segurança, KYC e suporte.

# PARTE 3/4 — Especificação de telas (índice consolidado)

**Cliente (11):** C1 Home · C2 Destino/Confirmar · C3 Negociar · C4 Fila · C5 Acompanhar · C6 Em viagem · C7 Revisão/Pagamento · C8 Avaliar · C9 Histórico · C10 Perfil/Pagamentos · C11 SOS (sheet). Árvores de componentes, matrizes de estados e microcopy conforme entrega da Parte 3 no histórico; hierarquia obrigatória do OfferCard: valor bruto 31 dp > coleta > total > destino ≈ > R$/h > cronômetro 15 s.

**Parceiro (8):** P1 Login/KYC · P2 Painel (chip modo + PassCard + CTA grande, sem abas) · P3 Oferta · P4 Em corrida (3 fases, deep link navegação) · P5 Confirmação dinheiro · P6 Passe · P7 Extrato/Carteira · P8 Tickets.

**Console (6):** K1 Dashboard · K2 Fila KYC (comparador + motivo padronizado) · K3 Suporte (contexto corrida + ações + re-auth) · K4 Financeiro (conciliação) · K5 Cidades/PRM (versionado com vigência + flags/kill switches) · K6 Corridas (timeline imutável).

**Microinterações:** oferta=pulso médio + vibração (som default OFF, ADX-UX-5); pagamento=pulso duplo; erro=2 pulsos; motion 150–200 ms, off com reduzir movimento.

**Decisões:** ADX-UX-1 mapa full-screen + bottom nav (cliente) · ADX-UX-2 parceiro tela única · ADX-UX-3 offline somente leitura + fila · ADX-UX-4 PIN opcional (automático noturno=V1) · ADX-UX-5 som oferta off · ADX-UX-6 re-auth no console para ações destrutivas.

# PARTE 4/4 — Protótipo, usabilidade, adversarial

- **Protótipo navegável:** `docs/prototipo/index.html` (arquivo único, sem build; aberto na aba de Preview). Cobre: cliente home→destino→fila→acompanhar→pagamento→avaliar; parceiro painel→oferta→corrida→confirmação; toggle OFFLINE demonstrando ADX-UX-3; cronômetro de oferta real; confirmação de dinheiro atualiza ganho e modo.
- **Plano de usabilidade (5 parceiros + 5 clientes):** ver seção abaixo.
- **Revisão adversarial (QA+SEC):** ver veredito abaixo.

## Plano de usabilidade

| Item | Definição |
|---|---|
| Amostra | 5 parceiros (2 com passe simulado, 3 sem) + 5 clientes; recrutamento nos pontos de embarque do Centro e B. São Pedro; incentivo: crédito de corrida [orçamento a definir] |
| Ambiente | 2 Android de entrada reais + 1 intermediário; 1 com rede limitada (3G simulado); sem Wi-Fi |
| Tarefas Cliente | (1) solicitar corrida em ≤ 3 toques; (2) negociar um preço; (3) compartilhar viagem + achar SOS; (4) pagar por Pix; (5) avaliar |
| Tarefas Parceiro | (1) comprar passe e ficar online; (2) ler e aceitar oferta em ≤ 3 s; (3) navegar (deep link) e finalizar; (4) declarar dinheiro; (5) ver extrato e entender modo |
| Métricas | Tempo por tarefa, erros, pedidos de ajuda, SUS (meta ≥ 68), taxa de conclusão sem assistência; ofertas avaliadas por legibilidade em ≤ 3 s |
| Critérios de saída | 8/10 completam solicitar sem ajuda; SUS ≥ 68 nas duas personas; 5/5 parceiros leem valor e R$/h corretamente em ≤ 3 s |

## Revisão adversarial (QA+SEC)

1. **Pre-mortem (top causas já mitigadas):** liquidez (seed), PSP/taxa (Pagar.me + kill switch), LC 856 (estado pendente de alvará), prazo (gates), fraude passe (servidor-centrista), Play BG (divulgação + teste), suporte (bot+7h-23h), Realtime (gate p95), marca (INPI antes de investir), escopo (todo pedido novo = ADR).
2. **Inconsistências:** resolvidas — passe vence em corrida (snapshot), no-show (espera 5 min sem falta), PSP cai (fila idempotente), cancelamento offline proibido (reoferta fantasma).
3. **Abuso:** parceiro declara "não recebi" em loop → ticket+antifraude; passageiro paga menos → divergência→ticket; contador de cancelamento por device+doc+tel; re-auth no console.
4. **Custo:** alarme ≤ 4 min idempotente (1 por corrida); push de dados; SMS só em fallback de emergência; polling de ETA proibido (R1).
5. **LGPD:** fotos com expiração 30 d; áudio (V1) com consentimento; consentimentos revogáveis por finalidade; link de compartilhamento com expiração; sem PII em logs.
6. **Veredito: COM RESSALVAS → APROVADO para GATE 1** — ressalvas: confirmar PRM-noShow.espera, PRM-pendencia.limite, horário noturno; testar haptic/vibração em aparelhos-referência.
