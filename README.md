# 10 é +

Plataforma de mobilidade urbana para Porto Velho/RO: corridas de carro e moto
com preço calculado na hora, passe diário do parceiro em vez de comissão por
corrida, e PIX. Dois apps Flutter — **passageiro** e **parceiro** — sobre um
contrato HTTP único ([`docs/fase2/openapi.yaml`](docs/fase2/openapi.yaml),
42 paths / 47 operações).

> **Estado:** o MVP-A funciona de ponta a ponta — buscar endereço, cotar,
> chamar, ser escolhido pelo ranking de despacho, aceitar, percorrer as fases
> da corrida, pagar com PIX confirmado pelo servidor, avaliar e ver carteira e
> desempenho. Isso roda hoje sobre a **API de demonstração**
> (`scripts/demo_api.py`), em memória. Do backend de produção existem o schema,
> o RLS e **uma** Edge Function. Leia [Limites conhecidos](#limites-conhecidos)
> antes de tratar qualquer parte como pronta para produção.

## O produto

| | Passageiro | Parceiro |
|---|---|---|
| Tela inicial | mapa em tela cheia e "Para onde?" | painel com chip do modo (PASSE/COMISSÃO), passe, carteira e CTA ONLINE/OFFLINE |
| Fluxo principal | endereço com número obrigatório → rota por ruas e preço do momento → chamar ou negociar → radar com parceiros reais no raio → acompanhar → pagar → avaliar | oferta com cronômetro de 15 s e justificativa da escolha → aceitar → a caminho / cheguei / em viagem → finalizar → declarar dinheiro |
| Também tem | histórico com recibo e mapa, convites, raspadinha, SOS, gravação de áudio | desempenho semanal, configuração de solicitações, veículos, carteira com extrato, convites, raspadinha |
| Tamanho | 16 telas · 35 testes | 19 telas · 34 testes |

## Arquitetura

```
   app/passageiro (Flutter)            app/parceiro (Flutter)
   16 telas · mapa · radar             19 telas · painel · oferta
            │                                  │
            └─────────── HTTP + JSON ──────────┘
                          │
                  contrato: docs/fase2/openapi.yaml
                  (Idempotency-Key, problem+json com `code`)
                          │
        ┌─────────────────┴──────────────────┐
        │  HOJE                          ALVO │
        ▼                                    ▼
  scripts/demo_api.py              Supabase (Postgres + Edge Functions)
  43 endpoints em memória          supabase/migrations (schema + RLS)
  despacho.py (ranking)            supabase/functions/radar  ← única pronta
  cotação, oferta, PIX, carteira   docs/fase2/0001..0005 (SQL da Fase 2)
```

Decisões que sustentam o produto (o porquê está em
[`docs/PRODUTO-MESTRE.md`](docs/PRODUTO-MESTRE.md)):

- **Despacho por ranking auditável**, não sorteio: ETA 0,40 · avaliação 0,20 ·
  taxa de aceite 0,15 · tempo ocioso 0,15 · experiência 0,05 · qualidade da
  posição 0,05, com anti-inanição e filtros separados do score
  ([`scripts/dispatch.py`](scripts/dispatch.py)).
- **Preço coerente e explicável**: cotação, oferta e recibo usam a **mesma
  distância de rota** (OSRM) e o card mostra a composição
  (`base · km · demanda · hora`).
- **Radar com presença real** do app do parceiro (tabela `partner_presence`),
  com posição aproximada e id pseudônimo — nada de motorista inventado.
- **Erro por `code`, nunca por mensagem**: as telas decidem por
  `code` (`problem+json`), não por texto de resposta.
- **PASSE × COMISSÃO é ortogonal ao despacho**: nunca bloqueia oferta, e a
  neutralidade é requisito testável (ADR-002 A4/A7).

## Como rodar

Pré-requisitos: **Python 3** (a demo usa só a biblioteca padrão; testado em
3.13), **Flutter 3.47 / Dart 3.13** (o `pubspec` exige SDK ≥ 3.4) e, para o
E2E, **Android SDK com adb e um AVD**.

### 1. API de demonstração

```bash
python scripts/demo_api.py --port 8787
```

Deixe rodando. Estado em memória: reiniciar zera corridas, carteira e calor.
`DEMO_LOG=1` mostra cada requisição (útil para depurar oferta e presença).

### 2. Apps

```bash
cd app/passageiro        # ou app/parceiro
flutter pub get
flutter run --dart-define=API_BASE=http://10.0.2.2:8787    # emulador Android
flutter run -d chrome --dart-define=API_BASE=http://127.0.0.1:8787
```

> **Sempre passe `API_BASE`.** O valor compilado por padrão no código aponta
> para o gateway do Supabase local (`…:8787/functions/v1/v1`), que a demo não
> implementa: sem o `--dart-define` acima, a demo responde
> `404 not_found` em toda chamada. Verificado nesta versão.

No emulador, `10.0.2.2` é o host. O login é OTP de desenvolvimento: qualquer
celular com DDD e qualquer código de 4 dígitos entram — **não há autenticação
real** (ver [Limites conhecidos](#limites-conhecidos)).

### 3. Testes e análise

```bash
cd app/passageiro && flutter test && dart analyze lib test    # 35 testes
cd app/parceiro   && flutter test && dart analyze lib test    # 34 testes
```

Use `dart analyze`, não `flutter analyze`: o servidor LSP desta máquina quebra
com o acento no caminho do projeto (`FormatException` no protocolo).

### 4. E2E dos dois apps no emulador

```bash
python scripts/e2e_emulator.py                  # sobe AVD + API isolada e conduz as duas UIs
python scripts/e2e_emulator.py --no-emulator --serial emulator-5554   # usa um device já aberto
```

Exit `0` = PASS. Ele compila e instala os APKs, opera as telas por adb e
confere o estado final no servidor; artefatos (capturas, `result.json`) vão
para `.preview/e2e_auto/<data>-a1/`. A API do teste roda isolada na porta 8790
para não sujar a demo de trabalho.

### 5. Uma semana de desempenho sem inventar histórico

```bash
python scripts/demo_api.py --port 8787 --time-travel   # terminal 1
python scripts/demo_week.py                            # terminal 2
```

O roteiro opera o relógio do servidor e executa o **caminho real** (online →
chamada → aceite/recusa/expiração → finalização → avaliação); quem agrega é o
servidor. Serve para popular a tela de desempenho do parceiro.

### 6. Banco e Supabase local

```bash
bash scripts/ci_db_suite.sh        # cadeia 0001→0005 em Docker, com asserts (ledger Σ=0)
supabase start                     # stack local (API em 54321)
python scripts/dev_jwt.py --role passenger    # JWT de desenvolvimento
python scripts/radar_smoke.py                 # smoke do radar real (presença no Postgres)
```

## Estado das fases

| Fase | Escopo | Estado |
|---|---|---|
| 0 | Produto, personas, premissas, unit economics | aprovada |
| 1 | UX e arquitetura de telas (C1–C11, P1–P7) | aprovada (GATE 1) |
| 2 | Schema, RLS, contrato OpenAPI, threat model, SLOs, custo | aprovada (GATE 2) |
| 3 | Apps passageiro e parceiro | **em andamento**: 35 telas, 69 testes, fluxo ponta a ponta executado sobre a demo. Faltam console de operação, autenticação real e as 42 operações do contrato no backend |
| MVP-B | Entregas, chat, cartão, navegação embutida, P8 tickets | não iniciado |

## Scripts

| Script | Para quê |
|---|---|
| `demo_api.py` | API de demonstração em memória: cotação, despacho, corrida, PIX, carteira, radar, raspadinha, convites |
| `dispatch.py` | Ranking de despacho (funções puras, auditáveis) |
| `dispatch_sim.py` | Simulador de despacho usado para fechar o orçamento de mapas |
| `test_dispatch.py` | Testes das funções puras do despacho |
| `e2e_emulator.py` | E2E dos dois apps no emulador, com classificação de falha (produto × infra) |
| `smoke_demo_api.py` | Smoke do contrato contra a demo, do pedido à avaliação |
| `smoke_dispatch.py` | Smoke do ranking contra a demo |
| `smoke_dispatch_app.py` | Despacho pelo caminho HTTP dos apps (sem `driver_id`) |
| `smoke_ride_pix.py` | Corrida completa até o PIX pelo mesmo caminho dos apps |
| `demo_week.py` | Uma semana de eventos reais para a tela de desempenho |
| `hold_search.py` | Segura a tela de busca com motorista no radar e vigia o emulador |
| `radar_smoke.py` | Smoke do radar real (Supabase local + Postgres) |
| `dev_jwt.py` | JWT de desenvolvimento para o Supabase local |
| `adb_ui.py` | Utilitário de UI Android usado pelos smokes |
| `ci_db_suite.sh` | Cadeia SQL 0001→0005 em container único (roda no CI) |

## Documentação

| Documento | Conteúdo |
|---|---|
| [`docs/PRODUTO-MESTRE.md`](docs/PRODUTO-MESTRE.md) | fonte única de verdade: premissas, REQ, ADRs, ledger, riscos, fases |
| [`docs/fase2/openapi.yaml`](docs/fase2/openapi.yaml) | contrato das operações, enums e códigos de erro |
| [`docs/fase2/SPECS.md`](docs/fase2/SPECS.md) | despacho (leva de 3, R(t)), motor de preço, anti-colusão, ETA sem polling |
| [`docs/fase2/0001..0005`](docs/fase2) | DDL, RLS e funções de domínio, smoke E2E, correções e suíte adversarial |
| [`docs/fase2/THREAT-MODEL.md`](docs/fase2/THREAT-MODEL.md) | STRIDE T-01..T-24 e trilha LGPD |
| [`docs/fase2/SLOS.md`](docs/fase2/SLOS.md) · [`CUSTO-CAPACIDADE.md`](docs/fase2/CUSTO-CAPACIDADE.md) | SLOs e custo de mapas em 1k/10k/100k corridas por dia |
| [`docs/REVISAO-FASE3.md`](docs/REVISAO-FASE3.md) · [`docs/REVISAO-FABLE.md`](docs/REVISAO-FABLE.md) | revisões com os defeitos encontrados e como foram medidos |
| [`app/passageiro/README.md`](app/passageiro/README.md) · [`app/parceiro/README.md`](app/parceiro/README.md) | detalhe de cada app e do seu fluxo |

## Limites conhecidos

1. **O backend real está no começo.** As 42 operações do contrato são servidas
   pela demo em Python; no Supabase existe apenas a Edge Function `radar`.
2. **Não há autenticação.** O login aceita qualquer código de 4 dígitos, a demo
   não lê `Authorization` e não há isolamento por usuário — carteira, KYC e
   passe são de um único estado global.
3. **PIX é ensaiado, não liquidado.** A demo faz o papel do webhook do PSP e
   sempre confirma; não há PSP integrado (alvo: Pagar.me, ADR-005) nem
   verificação de assinatura.
4. **O E2E é instável neste host.** Em 81 execuções registradas, 6 passaram; a
   maioria das falhas é o processo do emulador morrendo (53 de infraestrutura,
   7 de produto). O verde de referência é o CI (`e2e-emulator`).
5. **Preço depende de estado em memória**: o calor dos últimos 15 min sobe com
   cada pedido no mesmo ponto e satura — duas execuções seguidas diferem.
6. **Tiles do OpenStreetMap público.** Produção exige provedor próprio (a
   política de uso do OSM não cobre aplicativo em escala).
7. **Console de operação não existe.** Sem ele não há KYC manual, disputa ou
   suporte — é a lacuna para sair de piloto.
8. **Kit de marca bruto fora do repositório.** `10-e-mais-HD/` (88 MB de PNGs)
   fica no disco; os assets que os apps usam estão versionados em
   `app/*/assets/kit/`. Para versioná-lo, use Git LFS.
