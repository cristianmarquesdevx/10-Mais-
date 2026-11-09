# Refatoração completa — inventário, auditoria e plano

**Data:** 02/11/2026 · **Escopo:** `app/passageiro`, `app/parceiro`, `supabase/`, `scripts/`, `docs/`, kit de marca `10-e-mais-HD/`.
**Método:** FABLE Method (`/fable-method`, `.opencode/skill/fable-method/SKILL.md`) — classificação *plan-first*: este documento é o plano; nenhum arquivo de produto foi alterado.
**Regra seguida:** tudo abaixo foi lido ou executado nesta máquina. Onde não foi possível verificar, está marcado como não verificado.

---

## 1. Inventário real da pasta

### 1.1 Estrutura

| Caminho | Conteúdo | Estado |
|---|---|---|
| `app/passageiro/` | Flutter, 16 telas + 7 widgets, 16.816 linhas Dart (2 apps somados) | roda; 35 testes |
| `app/parceiro/` | Flutter, 19 telas + 5 widgets | roda; 34 testes |
| `supabase/` | `config.toml`, 4 migrations, `seed.sql`, 1 Edge Function (`radar`) | schema real, API quase inexistente |
| `scripts/` | `demo_api.py` (1.963 linhas, em memória), `dispatch.py`, 8 smokes, `e2e_emulator.py` | é o backend que os apps chamam hoje |
| `docs/` | produto mestre, fases 1–2, OpenAPI, threat model, SLOs, 30 capturas de E2E | ativo valioso |
| `10-e-mais-HD/` | 88 MB de PNGs (5.700×3.600 por tela) + 6 pastas de kit | bruto, fora do bundle |
| `.opencode/` | 100+ definições de agentes, skills (FABLE, design, segurança, memória) | não versionado em parte |

Plataformas geradas: `android` e `web` nos dois apps, `windows` no parceiro. **Não existe projeto `ios/` em nenhum dos dois** — o alvo iOS do pedido não tem nem scaffolding.

### 1.2 Dependências (idênticas nos dois `pubspec.yaml`)

`flutter_map ^8.3.2` (OSM), `http`, `intl`, `latlong2`, `shared_preferences`, `geolocator ^14.1.2`, `web`. SDK `>=3.4.0`.
Ausentes para o escopo pedido: `flutter_svg`, `lottie`/`rive`, `google_maps_flutter`, `supabase_flutter`, `firebase_messaging`, `connectivity_plus`, `flutter_secure_storage`, `image_picker`/`camera`, `flutter_stripe`/PSP, qualquer gerenciador de estado externo.

### 1.3 Assets visuais

| Item | O que existe | Formato / peso |
|---|---|---|
| Logo | `logo_completo.png`, `logo_texto.png`, `logo_icone.png`, `logo_branco.png`, `logo_transparente.png`, `logo_claro_alpha.png`, `logo_fundo_claro.png` | PNG raster, 40–132 KB cada; **sem vetor (SVG/AI/EPS)** |
| Veículos | `carro.png` (372 KB), `moto.png` (493 KB), `moto_no_mapa.png` (309 KB) | PNG grande, sem versão @2x/@3x dedicada |
| Navegação | `seta_voltar.png`, `menu_4pontos.png` | PNG |
| Mapa | `parceiro/assets/map/mapa.jpg` | JPG estático |
| Ícone do app | `mipmap-*/ic_launcher.png` + adaptive icon (`mipmap-anydpi-v26/ic_launcher.xml`) | existe, reaproveita o símbolo |
| Splash | `res/drawable/launch_background.xml` | **branco padrão do Flutter**, comentário de template intacto — sem marca |
| Ilustrações | nenhuma | — |
| Fontes | nenhuma (`fontFamily: null` → Roboto/SF do sistema) | — |
| Animações | nenhuma (3 ocorrências de `AnimationController`/`AnimatedContainer`/`Hero` em 16,8 mil linhas) | — |
| SVG / Lottie | **zero arquivos** em todo o repositório | — |

### 1.4 O TEAL em uso — dois valores diferentes

| Onde | Hex | Observação |
|---|---|---|
| `app/*/lib/src/theme/theme.dart` → `AppColors.primary` | **`#05998C`** | token primário declarado, igual nos dois apps; também `AppGradients.primary` (`#05998C → #35C4B6`) |
| `AppColors.primaryDark` | `#047A70` | estados pressionados/ênfase |
| `AppColors.primarySoft` | `#4FC9BC` | superfícies suaves |
| Pixel dominante do logo (`logo_icone.png`) | **`#18A195`** | 245 px de 208×208; ~10% mais claro que o token |
| `earn` (ganhos) | `#06796E` | — |

Contraste medido (WCAG 2.1):

| Cor | vs branco | vs preto |
|---|---|---|
| `#05998C` (token) | **3,53:1** | 5,94:1 |
| `#18A195` (logo) | **3,20:1** | 6,57:1 |
| `#047A70` (primaryDark) | 5,22:1 | 4,02:1 |

Consequência: **texto branco sobre o teal de marca não passa em AA para corpo de texto** (mínimo 4,5:1). Serve para texto grande (≥ 18,66 px bold / 24 px) e para componentes (3:1). O `FilledButton` do tema pinta o teal com `onPrimary` derivado do `ColorScheme.fromSeed` — precisa ser auditado tela a tela; o `GradientButton` já usa `AppColors.ink` sobre o gradiente (5,94:1, correto).

### 1.5 Onde cor, tipografia e espaçamento estão definidos

- **Definido:** `AppColors` / `AppColorsDark` (15 tokens cada), `tokensOf(context)`, `AppGradients` (5), `AppType` (8 estilos), `AppSpace` (grade 4 dp, raios 12/18/999, alvo 48 dp), `appShadow`/`appShadowDark`, `buildLightTheme()`/`buildDarkTheme()`.
- **Repetido / fixo:** `theme.dart` é **duplicado byte a byte** nos dois apps (≈ 430 linhas cada) — já divergiu (`AppGradients.warn` só existe no parceiro). Fora do tema há **17 `Color(0x...)`** em telas/widgets (destaques: `route_map.dart` 3× por app, `video_record_sheet.dart`, `perfil_screen.dart`, `offer_loss_sheet.dart`, `login_screen.dart`, `apresentacao_screen.dart`, `scratch_card.dart`) e **48 usos diretos de `Colors.white/black/red/grey/green`**.
- **Não existe:** escala tipográfica nomeada (display/título/corpo/legenda), tokens de elevação, de opacidade, de z-index, nem biblioteca de componentes além de `GradientButton`.

### 1.6 Telas existentes

**Passageiro (16):** login/apresentação · home com mapa · destino · negociar · fila/radar · acompanhar · viagem · pagamento · avaliar · histórico · detalhe da corrida · perfil · perfil-setup · convites · raspadinha (campanhas/play/histórico) · SOS (sheet).

**Parceiro (19):** onboarding · apresentação · login · painel (modo PASSE/COMISSÃO, calor, carteira, ONLINE) · oferta · navegação · em corrida · status da solicitação · passe · carteira · desempenho · configurar solicitações · veículos · perfil · histórico · convites · raspadinha · shell · setup do parceiro.

**Inexistentes:** entregas (fluxo, fotos, acompanhamento), chat 24 h, painel administrativo, tela/alarme de chegada em 4 min, onboarding ilustrado, telas de erro/estado vazio com ilustração.

### 1.7 Serviços e integrações efetivas

| Integração | Situação real |
|---|---|
| API | `scripts/demo_api.py` — 43 endpoints, estado em memória, CORS `*`, sem auth |
| Backend de produção | apenas `supabase/migrations/*.sql` (schema/RLS) + Edge Function `radar`; as outras 41 operações do contrato não têm servidor |
| Mapas | `flutter_map` + tiles públicos `tile.openstreetmap.org`, geocoding Nominatim, rotas OSRM demo — direto nos widgets, sem camada de troca efetiva |
| Localização | `geolocator` instalado; posição do parceiro é literal (`painel_screen.dart`), `heartbeat()` nunca chamado |
| Tempo real | não há; poll de 5 s com backoff nos dois controllers |
| Pagamentos | PIX simulado pelo próprio demo; sem PSP, sem cartão, sem webhook |
| Push | não há (FCM/APNs ausentes) |
| Auth | token por `--dart-define`, vazio por padrão; login aceita qualquer OTP de 4 dígitos |

### 1.8 Verificação executada agora

| Verificação | Comando | Resultado |
|---|---|---|
| Testes passageiro | `flutter test` | **35/35 verdes** |
| Testes parceiro | `flutter test` | **34/34 verdes** |
| Análise passageiro | `dart analyze lib test` | 0 issues (era 1 *info* antes da F0) |
| Análise parceiro | `dart analyze lib test` | 0 issues (era 1 *warning* + 1 *info* antes da F0) |
| Análise design system | `dart analyze` em `packages/ten_design` | 0 issues |
| Árvore de trabalho | `git status` | limpa (11 arquivos commitados na F0); `supabase/.env` agora ignorado |
| iOS | `ls app/*/ios` | **não existe** |

Flutter/Dart não estavam no `PATH`; usei `C:\Users\crist\flutter`. Os testes passam, mas o warning do parceiro e o `.env` sem `.gitignore` são regressões do trabalho em andamento.

---

## 2. Resumo do entendimento (10 linhas)

O 10 é + são dois apps Flutter (passageiro e parceiro) sobre um contrato OpenAPI, com um schema Postgres/PostGIS bem desenhado e **nenhum servidor de produção que o implemente** — hoje quem responde é uma demo em memória. O produto já tem fluxo completo de corrida (pedido → oferta → aceite → fases → pagamento → avaliação), carteira, passe, radar de presença, histórico e desempenho, com 69 testes verdes. O modelo de negócio é duplo: passe por tempo (100% do bruto para o motorista) ou comissão; mais taxa simbólica, entregas, limite de cancelamentos, KYC, chat e alarme de chegada. A marca é teal e o código já adotou `#05998C`, mas o logo raster está em `#18A195` e não há vetor. O visual é competente porém artesanal: tokens duplicados entre apps, 17 hex soltos, sem SVG, sem motion, sem fontes próprias, splash branco de template e ícone adaptativo genérico. Metade das regras do pedido (entregas, chat, admin, alarme, bloqueio de 12 h) não existe em nenhuma camada. O alvo iOS não foi gerado. A refatoração visual é viável, mas só entrega valor real se as regras saírem do Python de demonstração para o servidor, porque nenhuma delas pode ser imposta no cliente. Proponho começar pela base compartilhada (design system + núcleo), que é o que destrava todas as telas novas.

---

## 3. PONTOS A CONFIRMAR

| # | Ponto | Por que trava | Proposta padrão (configurável) |
|---|---|---|---|
| 1 | **Qual teal é o oficial** — `#05998C` (código) ou `#18A195` (logo) | define token, logo e contraste | manter `#05998C` como primário e reexportar o logo nele; confirmar com o manual de marca |
| 2 | **Manual de marca / vetor do logo** | não há SVG nem original; redesenhar sem vetor é recriação, não refatoração | recriar em SVG a partir do PNG e submeter à sua aprovação |
| 3 | **Comissão** — 12%? taxa simbólica por viagem: R$ 0,00 ou R$ 0,30–0,50? | está como pendência no `PRODUTO-MESTRE` §4 | comissão 12%; taxa simbólica R$ 0,00 no lançamento (ambas em `city_configs`) |
| 4 | **Passe** — R$ 10 / 12 h, por cidade? ativação no 1º online? | hoje `10.0` fixo em `demo_api.py:1784` | R$ 10 / 12 h por cidade, ativação no 1º online (A2) |
| 5 | **Entregas** — "cobrança acima de R$ 8" é piso de tarifa ou taxa adicional? | muda o motor de preço | R$ 8,00 = **piso da entrega**; taxa específica separada, ambas configuráveis |
| 6 | **Cancelamentos** — 5 por *semana calendário* ou 7 dias corridos? bloqueio de 12 h vale para os dois perfis? | `PRODUTO-MESTRE` diz rolling 7 dias; seu texto diz semana | rolling 7 dias, 5 cancelamentos, bloqueio 12 h para passageiro **e** parceiro, com contestação |
| 7 | **Alarme 4 min** — chegada do motorista ou ETA do passageiro? canal? | hoje inexistente; define push | local + push FCM/APNs de alta prioridade, idempotente, com fallback SMS |
| 8 | **FABLE Method** não foi colado — usei o do repositório | método de trabalho e gate | confirmar que é esse |
| 9 | **iOS** — não existe projeto e este host é Windows | não posso gerar/validar build iOS aqui | gerar `ios/` + CI macOS (Codemagic/GitHub macOS) para compilar e assinar |
| 10 | **Backend alvo** — Supabase (schema já pronto) ou evoluir a demo? | toda regra de negócio depende disso | Supabase: Postgres + RLS + Edge Functions; demo vira fixture de UI |
| 11 | **Provider de mapas** — Google (R1) ou OSM | custo mensal e termos; hoje OSM público em produção é proibido | Google atrás do `MapProvider`, OSM só em desenvolvimento |
| 12 | **Chat 24 h** — bot determinístico + humano 7h–23h? canal? | define modelo de dados e SLA | in-app, bot 24 h + fila humana, com transcript auditável |
| 13 | **Nome exibido** — "10 é +" ou "10 é Mais"? | `AndroidManifest` usa "10 é Mais", o app usa "10 é +" | padronizar "10 é +" no app e "10 é Mais" só onde o "+" quebra (loja) |
| 14 | **Retenção das fotos de entrega** (LGPD) | afeta Storage e exclusão | 90 dias, com trilha de auditoria e expurgo automático |

---

## 4. Auditoria inicial e riscos

Severidade: **C** crítico · **A** alto · **M** médio · **B** baixo.

### 4.1 Negócio e backend

| # | Sev | Achado | Evidência |
|---|---|---|---|
| A-01 | **C** | **Nenhuma regra de negócio é imposta pelo servidor.** As 42 operações do contrato são servidas por um Python em memória, sem auth; reiniciar apaga corridas, carteira e passe | `scripts/demo_api.py:1-31`; `GET /me` sem token responde 200 (diagnóstico F-01/F-15) |
| A-02 | **C** | **Limite de 5 cancelamentos/semana + bloqueio de 12 h não existe** em lugar nenhum: o endpoint só troca o status e nenhuma contagem semanal é feita | `demo_api.py:1182-1189`; zero ocorrências de "semana/bloqueio" nos SQL e no OpenAPI |
| A-03 | **C** | **Entregas não existem**: sem telas, sem tabela, sem upload de fotos, sem acompanhamento | 2 menções de "entrega" no código (texto); 0 em `openapi.yaml` |
| A-04 | **A** | **Chat 24 h, painel admin e alarme de 4 min não existem** | 0 ocorrências de `admin`, `alarme`; "chat" só em rótulo |
| A-05 | **A** | **Valores de negócio fixos em código**: passe `10.0`, comissão `0.12`, piso de negociação `15` | `demo_api.py:1784`, `:340`, `:493` — contraria "nunca fixos em código" |
| A-06 | **A** | ~~**Preço é escolhido pelo cliente**~~ **Fechado na demo em 07/11/2026**: o `GET /quote` emite `quote_id` e o `POST /rides` cobra o valor gravado no servidor (uso único, 90 s, vinculado à rota); o `quoted_fare` virou campo informativo. Falta persistir/assinar a cotação no backend real (Fase 2) | `scripts/demo_api.py` (`_resolve_quote`); `docs/REVISAO-FABLE.md` §5; `scripts/test_quotes.py` 9/9 |
| A-07 | **A** | **Despacho real não existe**; oferta nasce quando o parceiro consulta, sem raio/score/leva | `demo_api.py:736-810` (F-11) |
| A-08 | **M** | KYC tem status na UI, mas não há fila, SLA nem triagem no servidor | `status_solicitacao_screen.dart`, `perfil_screen.dart` |

### 4.2 Mobile e plataforma

| # | Sev | Achado | Evidência |
|---|---|---|---|
| M-01 | **C** | **Sem projeto iOS.** O pedido é Android + iOS | `app/passageiro/` e `app/parceiro/` só têm `android/`, `web/`, `windows/` |
| M-02 | **A** | **Modo escuro está quebrado nos dois apps**: o `ValueListenableBuilder` escuta a preferência, mas o `MaterialApp` fixa `themeMode: ThemeMode.light` | `app/passageiro/lib/main.dart:83`; `app/parceiro/lib/main.dart:84` |
| M-03 | **A** | **Sem tempo real**: poll de 5 s; oferta de 15 s pode chegar tarde; sem push | `ride_controller.dart`, `partner_controller.dart` |
| M-04 | **A** | **Localização real não é usada**: origem fixa e posição do parceiro literal; `heartbeat()` nunca chamado | `destino_screen.dart:33-36`, `painel_screen.dart:494` (F-02) |
| M-05 | **M** | **Resiliência offline/rede fraca não existe**: sem `connectivity_plus`, sem fila de escrita, sem cache de leitura | `pubspec.yaml`; controllers só têm backoff |
| M-06 | **M** | **Duplicação de tema e cliente entre apps** (≈ 430 linhas iguais), já com divergência | `theme.dart` dos dois apps |
| M-07 | **B** | `API_BASE` default aponta para caminho que a demo não serve (`…/functions/v1/v1`) | `main.dart:36-37` (F-17) |

### 4.3 Visual, design system e acessibilidade

| # | Sev | Achado | Evidência |
|---|---|---|---|
| V-01 | **A** | **Dois teais**: token `#05998C` × logo `#18A195`; arte e UI não batem | amostragem de pixel do `logo_icone.png` |
| V-02 | ~~A~~ | **Corrigido na F1 para os CTA**: texto branco sobre `#05998C` dava 3,53:1; agora é `onPrimary` (#12211F) a 4,70:1, com teste automatizado. Restam usos de teal como texto de 12–14 px nas telas, a migrar na F5. | cálculo WCAG + `packages/ten_design/test/contrast_test.dart` |
| V-03 | **A** | **Design system incompleto e espalhado**: 17 hex fora do tema, 48 `Colors.*` diretos, um único componente (`GradientButton`), sem escala tipográfica | `grep` em `app/*/lib` |
| V-04 | **A** | **Zero assets vetoriais e zero ilustração**; PNGs de até 493 KB no bundle; sem `flutter_svg` | `assets/`; `find -name "*.svg"` → 0 |
| V-05 | **A** | **Sem motion**: nenhuma transição própria, nenhum skeleton, nenhum respeito a "reduzir movimento" | 3 ocorrências de animação em 16,8 mil linhas |
| V-06 | **M** | **Splash é o template branco** do Flutter; ícone adaptativo sem camada de marca dedicada; sem splash iOS | `launch_background.xml` |
| V-07 | **M** | **Acessibilidade frágil**: 12 usos de `Semantics`/`tooltip` em 35 arquivos; sem teste de contraste; sem escala de texto validada | `grep` |
| V-08 | **M** | **Hierarquia e densidade irregulares**: telas misturam `Card` + `Container` decorado + `ListTile`; espaçamentos fora da grade em pontos | inspeção das telas do print |
| V-09 | **B** | **Referências visuais do repositório estão desatualizadas**: `docs/screens/*.png` mostram paleta verde, anterior ao teal atual — não servem de baseline | captura `e2e_01_parceiro.png` × `theme.dart` |

### 4.4 Higiene e processo

| # | Sev | Achado |
|---|---|---|
| P-01 | ~~A~~ | **Resolvido na F0.** `supabase/.env` ignorado (nunca chegou a ser commitado). |
| P-02 | ~~M~~ | **Resolvido na F0.** Os 11 arquivos foram revisados e commitados. |
| P-03 | ~~M~~ | **Resolvido na F0.** `dart analyze` zerado nos três projetos. |
| P-04 | ~~B~~ | **Resolvido na F0.** `flutter-quality.yml` roda análise, testes e contraste a cada push/PR. |

### 4.5 Checkpoint de supervisão — estado atual

1. **Alinhado às regras de negócio?** Não. Metade das regras não existe em nenhuma camada (A-02…A-04) e os valores estão no código (A-05).
2. **Consistente com o design system e o teal?** Parcial. Tokens existem, mas há dois teais, hex soltos e tema duplicado (V-01, V-03).
3. **Riscos de segurança, desempenho ou acessibilidade?** Sim: sem auth/RLS em execução (A-01), `.env` exposto (P-01), contraste reprovado (V-02), sem offline (M-05).
4. **Critérios de aceite da fase?** Os da Fase 3 (apps) estão cumpridos; os desta refatoração, não.

**Veredito:** **APROVADO COM AJUSTES para iniciar F1 e F2** (design system e marca são independentes do backend). **REPROVADO** para declarar o sistema "refatorado" enquanto F3/F4 não existirem — não se constrói entrega, chat, admin ou bloqueio de 12 h só na UI.

---

## 5. Plano de refatoração em fases

Premissa: **stack mantida** (Flutter + Supabase/Postgres). Nada de troca sem sua aprovação. Cada fase fecha com checkpoint de supervisão e não avança com pendência crítica.

| Fase | Entrega | Agentes | Depende de | Critérios de aceite (verificáveis) |
|---|---|---|---|---|
| **F0 · Congelar e higienizar** (2–3 dias) | commit do WIP revisado; `.env` no `.gitignore` + rotação; `dart analyze` 0; CI com lint | QA, Backend, DevOps | — | `git status` limpo; `dart analyze lib test` exit 0 nos dois apps; `flutter test` 69/69; nenhum segredo em arquivo rastreável |
| **F1 · Design system único** | pacote `10e_design` (tokens claro/escuro, tipografia, espaçamento, elevação, componentes: botão, campo, card, chip, sheet, banner, empty state, skeleton) + catálogo | Design Visual, Design de Produto, Mobile | F0 | 0 `Color(0x` e 0 `Colors.*` fora do pacote; contraste AA medido por teste automatizado em todos os pares texto/fundo; 1 fonte de verdade (tema deixa de ser duplicado); catálogo navegável |
| **F2 · Marca, ícone e splash** | logo vetorial (horizontal/vertical/símbolo, claro/escuro/mono), ícone adaptativo Android, AppIcon iOS, splash Android+iOS, sons/háptica | Design Visual, Motion, Mobile | F1 (para o teal canônico) | SVG versionados e usados no app; nenhum PNG de logo em uso; splash nativo com marca nas duas plataformas; ícone aprovado em máscara redonda/quadrada/squircle |
| **F3 · Núcleo de regras no servidor** | auth real (OTP/JWT), RLS ativo, `city_configs` versionada (passe, comissão, taxa, piso de entrega, limites), passe com fila FIFO, cancelamentos 5/7 dias + bloqueio 12 h, cotação assinada, despacho real com `FOR UPDATE`, KYC com fila/SLA | Arquitetura/Backend, Pagamentos, Segurança, QA | decisão §3.10 (backend) | Todos os valores vêm de `city_configs` (nenhum literal); teste de integração prova: 6º cancelamento bloqueia 12 h e 12 h depois libera; dois usuários não enxergam dados um do outro; cotação adulterada é rejeitada |
| **F4 · Entregas, chat, alarme e admin** | fluxo de entrega com 1–3 fotos (upload resiliente, compressão, expurgo), acompanhamento, piso de R$ 8; chat 24 h; alarme 4 min (push alta prioridade, idempotente); painel admin (config por cidade, KYC, disputas, métricas) | Backend, Mobile, Suporte/Operações, Design de Produto, QA | F3 | Fotos obrigatórias bloqueiam o envio sem imagem válida; alarme dispara uma única vez a ≤ 4 min; admin altera preço/comissão e o app reflete sem novo build; chat com transcript e SLA |
| **F5 · Refatoração de telas** (3 perfis) | todas as 35 telas sobre o pacote de componentes; estados de carregamento/vazio/erro; uso com uma mão; alvos ≥ 48 dp | Design de Produto, Mobile, Design Visual, QA | F1, F4 | Nenhuma tela com widget local de cor/tipografia; todos os estados desenhados; checklist de polegar (ações primárias no terço inferior); testes de widget por tela |
| **F6 · Motion e ilustrações** | splash, transições, busca de motorista, a caminho, confirmação de pagamento, alarme, feedback de toque; set de ilustrações SVG (onboarding, vazio, erro, entrega) | Motion, Design Visual, Mobile | F1, F5 | Cada animação ≤ 16 KB e 60 fps em aparelho básico; respeita `MediaQuery.disableAnimations` (teste); nenhuma animação bloqueia ação |
| **F7 · QA, performance e acessibilidade** | plano de testes, regressão, testes de a11y, orçamento de performance | QA, Mobile, Segurança | F5, F6 | TalkBack/VoiceOver navegam os fluxos críticos; contraste AA em todos os pares; cold start < 3 s; bundle de assets < 3 MB; suíte completa verde em CI (Android e iOS) |

### Dependências e caminho crítico

```
F0 ─┬─ F1 ─┬─ F2 ─────────────┐
    │      └─ F5 ── F6 ── F7
    └─ F3 ── F4 ─┘
```

F3 pode correr em paralelo a F1/F2 com outra frente; F5 espera F4 porque as telas de entrega/chat/admin ainda não existem.

### Checkpoint de supervisão (aplicado a cada fase)

1. Regras de negócio: os valores saíram do código? O servidor impõe, não a tela?
2. Consistência: só tokens do pacote? Teal único? Mesmos padrões nos três perfis?
3. Riscos: auth/RLS, contraste, alvos de toque, offline, bateria, peso.
4. Critérios de aceite da fase: todos observados por comando/teste, não por inspeção.

---

## 6. Arquitetura proposta

```
┌──────────────────────────── APPS (Flutter, um design system) ────────────────────────────┐
│  app/passageiro (Android · iOS)              app/parceiro (Android · iOS)                │
│  telas + navegação                          telas + navegação                           │
│         └──────────────┬─────────────────────────────┬──────────────────┘                │
│                        ▼                             ▼                                   │
│            packages/10e_design              packages/10e_core                            │
│            tokens, tipografia,              client HTTP, modelos, controllers,            │
│            componentes, motion              cache offline, MapProvider, auth              │
└───────────────────────────────────┬──────────────────────────────────────────────────────┘
                                    │ HTTPS/JSON + Realtime (WS) + push
                                    ▼
┌───────────────────────────── SUPABASE (fonte de verdade) ────────────────────────────────┐
│ Auth (OTP/JWT)  →  RLS em todas as tabelas  →  Storage (fotos, docs, áudio) com expurgo  │
│ Edge Functions (domínio)                                                                 │
│   quote · rides · offers/dispatch · passes · cancellations · deliveries · chat · admin     │
│ Postgres + PostGIS                                                                        │
│   cities/city_configs (versionada) · rides · offers · offer_events · passes · ledger       │
│   deliveries · delivery_photos · chat_threads · cancellation_events · kyc_queue            │
│ Realtime: canais por corrida/oferta   ·   Jobs: alarme 4 min, expurgo, SLA KYC             │
└───────────────┬───────────────────────────────┬──────────────────────────────┬────────────┘
                │                               │                              │
        MapProvider                       PSP (PIX/cartão)                 Push FCM/APNs
     (Google ⇄ OSM, troca              checkout hospedado,                alarme, oferta,
      sem tocar nas telas)             webhook assinado, ledger            status da corrida
```

Decisões e trade-offs:

- **Pacote compartilhado em vez de tema duplicado.** Custo: um `path:` no `pubspec` e um refactor inicial. Ganho: impossível divergir; uma correção de contraste vale para os dois apps.
- **Regra no servidor, tela só apresenta.** Custo: F3 é a fase mais longa. Ganho: cancelamento, passe e preço deixam de ser "decorativos" e passam a ser auditáveis.
- **`city_configs` versionada em vez de constantes.** Custo: mais uma tabela e cache. Ganho: muda preço/comissão sem publicar app, que é o que você pediu explicitamente.
- **Push + Realtime em vez de poll.** Custo: dependência de FCM/APNs e canal autenticado. Ganho: oferta de 15 s e alarme de 4 min viram possíveis; bateria e dados caem.

---

## 7. Próximo passo concreto

**F0 concluída.** O trabalho pendente foi revisado e commitado, `supabase/.env` entrou no `.gitignore`, o `dart analyze` está zerado nos três projetos e o CI ganhou o gate `flutter-quality`. A F1 começou junto: `packages/ten_design` já existe com tokens (teal único `#05998C`), tipografia, espaçamento, tema claro/escuro e cinco componentes, mais o teste de contraste que impede regressão de AA.

Para fechar F1 (catálogo e migração das telas) e iniciar F2, preciso de quatro respostas:

1. O teal oficial é `#05998C` (código) ou `#18A195` (logo)?
2. Existe vetor/manual de marca do logo, ou autorizo a recriação em SVG a partir do PNG?
3. Backend alvo: Supabase (recomendado) ou continuar sobre a demo?
4. Comissão 12% / passe R$ 10 por 12 h / taxa simbólica R$ 0,00 — confirmo esses defaults?

Com essas respostas eu abro F1 (pacote `10e_design`) e F2 (marca) na mesma leva, sem tocar em regra de negócio.
