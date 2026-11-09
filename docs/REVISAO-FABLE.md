# Revisão com o método Fable — cotação, OSRM e os dois apps (23/10/2026)

Pedido: "cotação R$ 8,04 + rota OSRM — o que aconteceu? Temos de resolver.
O app passageiro e o motorista têm de funcionar 100%. Revise tudo."

Método instalado em [`.opencode/skill/fable-method`](../.opencode/skill/fable-method/SKILL.md)
(MIT, `Sahir619/fable-method`; também `fable-loop`, `fable-judge`,
`fable-domain`). O loop: classificar o pedido → definir "pronto" → coletar
evidência → decidir → editar cirurgicamente → verificar por observação →
relatar resultado primeiro.

## 1. Resposta direta: a cotação não é fixa, e nunca foi

Nada quebrou entre "R$ 11,04" e "R$ 8,04". `GET /quote` é **tarifa
dinâmica** e o número muda com a hora e com o calor da zona — o valor citado
na documentação era uma foto de um horário, não o preço da corrida.

Medições reais nesta revisão (`python scripts/demo_api.py`, mesma rota de
1,2 km no Centro de Porto Velho):

| Momento | Cotação | Composição |
|---|---|---|
| 15h (execução do E2E documentada) | R$ 11,04 | base 8,30 × demanda 1,33 × hora 1,00 |
| 7h50 (rush) | R$ 13,03 | base 8,30 × demanda 1,33 × hora 1,18 |
| 7h51, após mais um pedido no mesmo ponto | R$ 13,22 | demanda saturou em 1,35 |
| madrugada | ≈ R$ 8,03 | base 8,30 × demanda 1,10 × hora 0,88 |

> Valores de 22/10, quando a base ainda usava `max(1,5 km, haversine)`.
> Hoje a base sai da distância da rota (1,227 km → R$ 7,70), então os
> mesmos horários dão ~10% menos. O que não muda é a coerência da cadeia.

Fórmula (`scripts/demo_api.py`, `_quote`): `base = 5,00 + 2,20 × km` onde
`km` é a distância rodoviária do OSRM (fallback Haversine × 1,35),
`demanda = 1,00 + 0,35 × peso da zona` (calor dos últimos 15 min, e **cada
`POST /rides` grava um hit** na origem), `hora = 1,18` no rush, `0,88` até
5h, `1,00` no resto.

O que importa e foi confirmado por observação: **o valor é o mesmo em toda a
cadeia**. `GET /quote` → `POST /rides` congela o valor no servidor →
`amount` da oferta no parceiro → `fare_total` final. No teste ao vivo:
cotação 13,03 → oferta 13,03 → corrida `FINALIZADA` com 13,03.

> **Atualizado em 07/11/2026:** o congelamento passou a ser do **servidor**.
> O `GET /quote` emite um `quote_id` de uso único e o `POST /rides` apresenta
> esse id — o `quoted_fare` do corpo virou campo **informativo** (se
> divergir do valor gravado, o pedido é recusado com 422
> `quote_fare_mismatch`). Ver §5.

A rota OSRM também está correta: `router.project-osrm.org` devolveu 1.226,7 m
/ 144,6 s para as coordenadas da demo, e o app mostra "1,2 km · 3 min" — o
mapa usa a rua de verdade, não a linha reta.

## 2. O que a revisão encontrou de verdade

**Defeitos corrigidos nesta rodada**

1. **Preço sem explicação.** O card mostrava só "Valor no momento · R$ X" e
   "vale por 90s". Quem via R$ 8,03 de madrugada e R$ 13,03 às 7h não tinha
   como saber por quê. O card agora imprime a composição
   (`Base R$ 7,64 · 1,2 km · demanda ×1,33 · hora ×1,18`).
   `app/passageiro/lib/src/screens/destino_screen.dart`.
2. **Cotação vencida virava preço cobrado.** `_chamar` mandava
   `quoted_fare: _quote?.fareTotal` mesmo com a cotação expirada (tela parada
   ou rede oscilando): o servidor congelava um valor que o card já não
   prometia. Agora o app re-cota antes de chamar e, se não conseguir, manda o
   pedido sem snapshot (o servidor decide).
3. **Falha de ambiente parecia bug do app.** `scripts/smoke_demo_api.py`
   quebrava com `AssertionError: POST /rides cria a corrida` quando a demo já
   tinha corrida ativa (409 `active_ride_exists` é o comportamento correto).
   Agora o script diz o que houve e como resolver.
4. **Tarifa e mapa mediam distâncias diferentes.** A cotação usava
   `max(1,5 km, haversine)` e o mapa desenhava a rota do OSRM (1,2 km): o
   "R$ 2,20 por km" não fechava com a tela. `GET /quote` agora mede pela rota
   (OSRM, cache de 10 min, fallback Haversine × 1,35) e precifica o km
   arredondado que o card exibe — 1,2 km → base R$ 7,64, e quem refizer a
   conta chega no mesmo centavo.
5. **Oferta e recibo contavam outro km.** A oferta usava Haversine × 1,35
   por conta própria e o recibo não trazia distância nenhuma. Agora o pedido
   grava `distance_km` (rota do OSRM) e os dois repetem esse valor; o
   passageiro vê o km no recibo (linha "Distância") e em cada corrida do
   histórico; tocar numa linha abre os detalhes com mapa da rota, valores e
   status.
6. **Documentação vendia um preço fixo.** `docs/REVISAO-FASE3.md` §3.2/§3.6 e
   `docs/PRODUTO-MESTRE.md` §8f falavam "R$ 11,04" como se fosse a tarifa.
   Corrigidos para "cotação do momento", com a fórmula em
   [§3.7 do REVISAO-FASE3](REVISAO-FASE3.md).

**Verificado e são OK**

- `flutter test`: **25/25** passageiro (um teste novo: cotação vencida é
  re-cotada antes do `POST /rides`) e **18/18** parceiro.
- `dart analyze`: 0 issues nos dois apps.
- `scripts/smoke_demo_api.py` contra API limpa: PASS no fluxo inteiro
  (pedido → oferta com o mesmo valor → aceite → A_CAMINHO → CHEGOU →
  EM_VIAGEM → FINALIZADA → PIX → avaliação → carteira).
- `GET /offers/mine` mostra `amount` igual ao `quoted_fare` congelado e
  `trip_distance_km` igual ao `distance_km` da corrida, que o recibo
  (`GET /rides/{id}`) repete — ao vivo, 1,2 km nas quatro pontas
  (card, corrida, oferta, recibo). O smoke passou a assertar essa cadeia.
- OSRM responde e o app desenha a rota por ruas (fallback local existe e está
  testado em `test/route_service_test.dart`).

**Fraquezas conhecidas (não bloqueiam o MVP-A)**

- **E2E de UI no emulador é intermitente neste host.** Em 23/10 o fluxo
  completo passou duas vezes na tentativa 1 com o código atual: 09:45
  (`.preview/e2e_hoje/20261023-094557-a1`, R$ 12,08) e 09:58
  (`.preview/e2e_final_hoje/20261023-095842-a1`, R$ 10,16); entre as duas, uma
  execução perdeu o dispositivo durante o login do parceiro
  (`20261023-095347-a1`, `failure_kind: infra`). O processo do emulador
  37.2.12 às vezes sai sozinho logo depois do primeiro frame do app
  passageiro (guest log mostra o pedido ao `IAllocator` gráfico). Tentado:
  `-feature -Vulkan`, `swiftshader_indirect`, `gpu guest`, headless, guest de
  2 GB, AVD dedicado, build antes do boot — nada muda o desfecho quando ele
  acontece. O harness classifica como `infra` e repete; o verde de
  referência continua sendo o CI (`e2e-emulator`, API 35).
- **`flutter analyze` quebra neste caminho.** O projeto mora em `10é+` e o
  servidor LSP corta a mensagem no caractere acentuado do path
  (`FormatException: Unexpected end of input`, exit 255) — não é lint.
  `dart analyze lib test` roda limpo nos dois apps e é a checagem usada.
- ~~Cotação, oferta e recibo com km diferentes~~: resolvido em 23/10. O
  pedido congela `distance_km` (rota do OSRM, mesma função da cotação) e a
  oferta (`trip_distance_km`) e o recibo (`GET /rides/{id}`) repetem esse
  número — verificado ao vivo: 1,2 km nas quatro pontas.
- Preço depende de estado em memória (calor): duas execuções seguidas no
  mesmo ponto sobem a demanda até o teto. É aceitável em demo, mas explica
  variação entre execuções.

## 3. Plano priorizado

| # | Ação | Por quê | Status |
|---|---|---|---|
| P0 | Mostrar a composição do preço no card | o número deixa de parecer arbitrário | feito |
| P0 | Re-cotar cotação vencida antes de chamar | preço mostrado = preço cobrado | feito |
| P0 | Docs sem preço fixo + §3.7 com a fórmula | evita o próximo "o que aconteceu?" | feito |
| P0 | Cotação pela distância da rota (OSRM), sem piso de 1,5 km | tarifa e mapa contam o mesmo km | feito 23/10 |
| P1 | Smoke falhar explicando estado sujo | diagnóstico, não bug fantasma | feito |
| P1 | Rodar o `e2e-emulator` no Actions e anexar o `result.json` | é o único verde de UI confiável hoje | pendente |
| P2 | `trip_distance_km` da oferta pelo mesmo `_road_km` da cotação | parceiro e passageiro com o mesmo km em qualquer rota | feito 23/10 |
| P2 | Congelar a cotação no servidor por `quote_id` + `expires_in` (a demo aceitava qualquer `quoted_fare`) | fecha o furo entre cotação e pedido | **feito 07/11/2026** (§5) |

## 4. Como reproduzir a revisão

```bash
python scripts/demo_api.py --port 8799                     # terminal 1
python scripts/smoke_demo_api.py --base http://127.0.0.1:8799
curl "http://127.0.0.1:8799/quote?origin_lat=-8.7607&origin_lon=-63.9039&dest_lat=-8.7647&dest_lon=-63.8969"
cd app/passageiro && flutter test && dart analyze
cd app/parceiro   && flutter test && dart analyze
```

## 5. P2 fechado — a cotação congela no servidor (07/11/2026)

O item P2 do plano (§3) era o furo real entre **preço mostrado** e **preço
cobrado**: o `POST /rides` aceitava o `quoted_fare` do corpo e virava
`fare_total`. Qualquer cliente podia escrever o preço da corrida, do recibo
e do lançamento na carteira.

**O que mudou**

| Antes (23/10) | Agora (07/11) |
|---|---|
| `GET /quote` devolve só `fare_total` + `expires_in` | devolve **`quote_id`** + `fare_total` + `expires_in` |
| `POST /rides` aceita `quoted_fare` do cliente | **`quoted_fare` é informativo**; quem manda é o valor gravado no servidor |
| cotação vencida ainda era cobrada | cotação vencida → 422 `quote_expired` |
| cotação de outra rota era aceita | rota diferente → 422 `quote_mismatch` (tolerância de ~50 m no GPS) |
| cotação podia ser reenviada | uso **único**: reenvio → 422 `quote_not_found` |
| app mandava só o número | app manda `quote_id` + `quoted_fare` (que só confere) |

**Regras** (`scripts/demo_api.py`)

- `QUOTE_TTL_S = 90` — mesmo `expires_in` que o card promete.
- `STATE["quotes"]` guarda `fare_total`, `expires_at`, origem e destino de
  cada cotação emitida.
- `_resolve_quote()`: com `quote_id` válido, devolve o valor gravado; **sem
  id, o servidor recalcula pela rota** e ignora o `quoted_fare` do corpo
  (nunca cobra preço de cliente).
- Se o `quoted_fare` enviado divergir do valor congelado → 422
  `quote_fare_mismatch` (tolerância de meio centavo).
- Cotações vencidas são expurgadas do estado 5 min depois do prazo (a
  resposta `quote_expired` continua correta nesse intervalo).

**Contrato** (`docs/fase2/openapi.yaml`): `Quote.quote_id` e
`RideRequest.quote_id` (uuid), com `quoted_fare` documentado como
"informative only". A corrida devolve `Ride.quote_id` — a **auditoria** de
qual cotação foi honrada (null quando o servidor recalculou sem cotação).

**App do passageiro**: `Quote.quoteId` → `createRide(quoteId)` →
`requestRide(quoteId)` → `destino_screen.dart` envia o id da cotação que
está na tela (re-cotando antes, se ela tiver vencido).

**Verificação**

- `python -m unittest discover -s scripts -p "test_*.py"` → **23/23** OK
  (12 de despacho + **11 de cotação** em `scripts/test_quotes.py`).
- Smokes contra API limpa: `smoke_demo_api`, `smoke_dispatch`,
  `smoke_dispatch_app`, `smoke_ride_pix` → **PASS** (os três primeiros
  passaram a emitir `quote_id` antes do pedido).
- Flutter passageiro: **63/63** (teste novo em `api_client_test.dart`
  conferindo `quote_id` no corpo) + `dart analyze lib test` limpo.
- E2E no emulador: corrida `133ac60e`, R$ 7,50, FINALIZADA/CONFIRMED/
  avaliada — artefatos em `.preview/e2e_auto/20261107-150427-a1`.
- **E2E com a cadeia da cotação** (20261107-162241-a1): o harness lê o
  preço **na tela** (R$ 7,50), confere no fim que o `fare_total` é o mesmo
  e exige o `quote_id` na corrida — corrida `8c248d4f`, cotação `f016a99a`,
  R$ 7,50 dos dois lados.

**O que continua fora do escopo da demo**: a cotação vive em memória
(`STATE["quotes"]`), sem assinatura criptográfica e sem persistência. No
backend real, `quote_id` vira registro no Postgres (Fase 2) com o mesmo
contrato: o cliente apresenta o id, o servidor decide o preço.
