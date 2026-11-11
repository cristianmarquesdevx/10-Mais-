# Diagnóstico técnico — Fase 1

**Data:** 24/10/2026 · **Escopo:** apps `passageiro` e `parceiro`, contrato `docs/fase2/openapi.yaml`, DDL `docs/fase2/0001–0005`, API executável `scripts/demo_api.py`, mapas/geocoding/rotas.
**Regra seguida:** nada de código de produto foi alterado nesta fase. Este documento é a entrega do GATE 1.

---

## 0. Veredito em uma página

Os **fluxos de tela** (pedido → oferta → aceite → fases → pagamento → avaliação) funcionam e estão cobertos por testes. O que está **por baixo** deles não é operável: não existe servidor de produção no repositório, não existe localização real de ninguém, e as duas peças que este prompt pede para construir — o radar de busca e o mapa de chamadas — hoje são **dados fabricados**.

| Pergunta do prompt | Resposta curta |
|---|---|
| O radar mostra motoristas reais? | **Não.** Três pinos sintéticos (`demo-driver-0..2`), sempre disponíveis, mesmo veículo, posições calculadas como `lat + offset`. |
| A quantidade de motoristas exibida corresponde a conectados/elegíveis? | **Não existe contagem.** O que aparece é o desenho desses 3 pinos e, no app do motorista, "38 chamadas/h" por zona — números inventados. |
| O mapa de chamadas usa locais reais? | Os **tiles** são reais (OSM), mas os **rótulos das zonas** estão errados/inventados e as coordenadas não correspondem aos bairros que nomeiam (provado por geocodificação reversa, F-06). |
| A tarifa segue a política documentada? | **Não.** É `5,00 + 2,20 × km` com multiplicadores fixos; sem piso, sem minuto, sem espera, sem taxas, sem `city_configs`, sem simulação. |
| O preço mostrado é o preço cobrado? | **Sim, desde 07/11/2026 na demo.** O `GET /quote` emite `quote_id` e o `POST /rides` cobra o valor gravado no servidor (uso único, 90 s, vinculado à rota). O `quoted_fare` do cliente é campo **informativo**. No backend real ainda falta persistir/assinar a cotação (Fase 2). |
| Existe tempo real? | **Não.** Nenhum WebSocket/SSE/Supabase Realtime; os dois apps fazem poll de 5 s com backoff. |
| Existe backend real? | Existe **especificação** (DDL + RLS + OpenAPI) e existe **demo em memória**. O código das Edge Functions não está no repositório. |

Consequência prática: as fases 2, 3 e 5 do prompt **não são um ajuste de tela**; dependem de uma base de presença/despacho/eventos. É por isso que o gate existe.

---

## 1. Arquitetura como está hoje

### 1.1 Duas camadas que não se tocam

| Camada | O que existe | Onde | Estado |
|---|---|---|---|
| Apps | Flutter 3.47.7 / Dart 3.13.5, `flutter_map` + OSM, `http`, `latlong2`, `shared_preferences` | `app/passageiro`, `app/parceiro` | Funciona; UI e clientes testados |
| Contrato | OpenAPI 3 com ~40 operações, JWT, `Idempotency-Key`, problem+json | `docs/fase2/openapi.yaml` | Validado; **não há servidor que o implemente** |
| Banco | DDL Postgres 16 + PostGIS, RLS deny-by-default, funções de domínio, partições, ledger | `docs/fase2/0001–0005` | Roda em CI (`scripts/ci_db_suite.sh`); **não é o banco que os apps usam** |
| API executável | Servidor HTTP Python de arquivo único, estado em memória, CORS `*`, sem auth | `scripts/demo_api.py` | É o que os apps realmente chamam |
| Mapas | Tiles `tile.openstreetmap.org`, geocoding `nominatim.openstreetmap.org`, rotas `router.project-osrm.org` | ambos os apps + demo | Dados reais, **serviços públicos** (sem contrato/SLA) |
| Tempo real | — | — | **Inexistente**; poll 5 s (`ride_controller.dart`, `partner_controller.dart`) |

O próprio `demo_api.py` declara no docstring: *"API de DEMONSTRAÇÃO — não é o backend real (…) estado em memória, sem auth real, sem ledger"*. Não há `supabase/`, `functions/`, `package.json` ou qualquer arquivo TypeScript/Deno no repositório. Ou seja: **o "backend próprio leve + Postgres" do documento mestre existe como projeto, não como software em execução.**

### 1.2 O que os apps chamam (e o que isso significa)

- `POST /rides` cria a corrida e cobra o preço **do servidor**: desde
  07/11/2026 a cotação congelada vem por `quote_id` (uso único, 90 s,
  vinculada à rota); sem id, o servidor recalcula pela rota. O
  `quoted_fare` do corpo é apenas informativo (F-09, fechado na demo).
- `GET /offers/mine` **gera ofertas sob demanda** para qualquer corrida `BUSCANDO` — não há motorista, raio, score ou distância envolvidos.
- `GET /partners/nearby` devolve motoristas sintéticos.
- `GET /heatmap` devolve zonas com pesos e "chamadas/hora" semeados em código.
- `POST /partner/transitions` muda o status; não emite eventos.
- Nenhuma rota verifica identidade: `GET /me` responde `200` sem `Authorization` (verificado ao vivo).

---

## 2. Onde está cada função que o prompt pede (item 3 da Fase 1)

| Função | Arquivo(s) | Como funciona hoje | Veredito |
|---|---|---|---|
| Busca de motoristas | `app/passageiro/lib/src/screens/fila_screen.dart:51-58`; `widgets/driver_radar.dart`; `scripts/demo_api.py:862-876` | Consulta `/partners/nearby` **uma vez** no `initState`, com centro fixo do Centro de Porto Velho; desenha os pinos numa `MarkerLayer` | Sem busca real, sem ciclo de atualização, sem estados |
| Solicitação e distribuição de chamadas | `demo_api.py:433-465` (pedido) e `:736-810` (oferta) | A oferta nasce quando o parceiro consulta; qualquer corrida `BUSCANDO` vira oferta se o tipo estiver ligado | Não há despachante: sem raio, score, leva de N, exclusão de recusados |
| Mapa de chamadas | `demo_api.py:148-165` (`HEAT_ZONES`), `:878-892` (`/heatmap`); `app/parceiro/lib/src/widgets/heatmap_map.dart`; `painel_screen.dart:93,128` | Círculos de calor por zona + rótulo "Bairro · N chamadas/h" | Dados semeados; rótulos errados; ver F-06 |
| Cálculo de tarifas | `demo_api.py:337-360` | `base = 5,00 + 2,20 × km`; demanda por peso de zona + 0,07 por chamada recente; rush por hora do servidor | Motor simplificado e divergente da SPECS §2 |
| Rastreamento da localização | **não existe** | Posição do parceiro é um literal em `painel_screen.dart:494`; `ApiClient.heartbeat()` (`client.dart:544`) **nunca é chamado** | Presença estática; radar/ETA/despacho sem fonte de verdade |
| Atualização de status | `demo_api.py:198-235` (auto-avanço), `:840-861` (transições) | O simulador avança por tempo **lendo** o estado; o app descobre por poll | Sem eventos, sem trilha auditável no runtime |

---

## 3. Achados

Legenda de severidade: **C** = crítico (impede operação real) · **A** = alto (contradiz o contrato/prompt) · **M** = médio (risco) · **B** = baixo (higiene).

### F-01 · C — O backend executável é a demo em memória
**Evidência:** `demo_api.py:1-30` (docstring), `:951-1045` (servidor), ausência de qualquer código de Edge Function no repo; `GET /me` sem token responde `200` (executado).
**Causa:** a Fase 2 entregou DDL + contrato, e a Fase 3 entregou apps sobre uma demo; a implementação do servidor ficou fora do escopo.
**Impacto:** qualquer recurso "real" (presença, despacho, contador, tarifa versionada, auditoria) não tem onde persistir. Reiniciar o processo apaga corridas e carteira.
**Solução:** implementar o servidor do contrato (Edge Functions + Postgres local) e apontar os apps para ele; manter a demo como *fixture* de UI, nunca como verdade.

### F-02 · C — Não existe localização real em nenhum dos dois apps
**Evidência:** `destino_screen.dart:33-36` e `:191` (origem fixa `-8.7607,-63.9039` e endereço literal "Centro, Porto Velho - RO"); `fila_screen.dart:28`; `city_map.dart:24`; `painel_screen.dart:494`; `heatmap_map.dart:19`; `pubspec.yaml` sem `geolocator`/`location`; `heartbeat()` sem chamadas.
**Causa:** durante a Fase 3 a localização foi tratada como "ponto de troca do MapProvider", mas o ponto nunca foi trocado.
**Impacto:** o passageiro pode estar em qualquer bairro e o pedido sai do Centro; o motorista fica "online" no Centro para sempre; radar, distância de coleta, ETA e despacho por raio ficam impossíveis.
**Solução:** captura com permissão (foreground + background no parceiro), envio periódico de posição com `stale_after`, e uso da posição real na cotação, na oferta e no radar; fallback explícito "localização indisponível" em vez de coordenada fixa.

### F-03 · C — O radar inventa motoristas
**Evidência:** `demo_api.py:868-874` — três objetos `demo-driver-N` com `lat + 0.004`, `available: true`, `vehicle: "Honda Biz 125"`; `fila_screen.dart:51-58` desenha sem distinguir simulação; `driver_radar.dart:35-47` filtra só por `available`.
**Causa:** a demo precisava de algo para a tela da fila não ficar vazia.
**Impacto:** viola diretamente "não simule motoristas, posições ou resultados inexistentes" e cria expectativa falsa de liquidez.
**Solução:** `/partners/nearby` passa a ler `partner_presence` (ONLINE_DISPONIVEL, heartbeat fresco, dentro do raio) com posição **aproximada**; sem parceiros, a tela mostra "nenhum motorista por perto" e o servidor amplia o raio — nunca pinos decorativos.

### F-04 · C — O simulador fabrica um motorista e conclui a corrida
**Evidência:** `demo_api.py:168-235` — após `DEMO_AUTO_ACCEPT_S` (12 s por padrão), a corrida ganha `driver: "sim"`, parceiro "Seu Raimundo (simulado)", veículo "Honda Biz 125", e avança ACEITA → A_CAMINHO → CHEGOU → EM_VIAGEM → FINALIZADA **na leitura**.
**Causa:** permitir demonstrar o fluxo do passageiro sem abrir a aba do parceiro.
**Impacto:** é exatamente "criar dados falsos para simular sucesso". Também esconde falha de liquidez e contamina qualquer métrica (aceitação, tempo de matching).
**Solução:** simulação só com flag explícita (`DEMO_MODE=1`) e etiqueta visível na UI; em modo real, prazo esgotado = `EXPIRADA`/`BUSCANDO` com raio ampliado — nunca um motorista fantasma.

### F-05 · A — O "radar" não é um radar
**Evidência:** `fila_screen.dart:110-155` — mapa comum com 3 pinos; nenhuma varredura, nenhuma onda concêntrica, nenhum contador de elegíveis, nenhum estado além de "Procurando…" (`:176`); `driver_radar.dart` só posiciona marcadores; atualização única em `initState`.
**Causa:** a tela C4 foi entregue como mapa + cronômetro, não como radar.
**Impacto:** os 8 estados visuais pedidos (aguardando localização, buscando, encontrados, enviada, aceitou, nenhum, erro, cancelada) não existem; a espera não informa nada.
**Solução:** widget de radar com `AnimationController` (varredura + ondas), estados dirigidos pelo servidor e contador de elegíveis vindo do despacho; timer de refresh curto só enquanto `BUSCANDO`, parando no aceite/cancelamento.

### F-06 · A — O mapa de chamadas mostra demanda inventada com nomes errados
**Evidência:** `demo_api.py:148-165` (sete zonas com `weight` e `calls_last_hour` fixos); `heatmap_map.dart:151-170` imprime "`label` · `calls_last_hour` chamadas/h"; `painel_screen.dart:128` mostra a pílula de zonas.
Prova por geocodificação reversa (Nominatim, 24/10/2026):

| Rótulo no app | Coordenada | O que existe ali (reverso) | Diagnóstico |
|---|---|---|---|
| Centro | -8.7607,-63.9039 | Rua Gonçalves Dias, **Centro** | correto |
| Aeroporto | -8.7647,-63.8969 | Rua Paulo Leal, **KM-1** | **errado** — aeroporto real em -8.7098,-63.9010, ~6 km ao norte |
| B. São Pedro | -8.7553,-63.9106 | Rua Abunã, **Arigolândia** | **errado** |
| 14 de Julho | -8.7688,-63.9011 | Rua Treze de Setembro, **Mocambo** | **errado** |
| Jardim Aero | -8.7521,-63.8955 | Rua Abunã, **São João Bosco** | **errado** |
| Distrito Industrial | -8.7745,-63.9105 | **Triângulo** | **errado** |
| Nova California | -8.7478,-63.9033 | **São João Bosco** | **errado** — "Nova Califórnia" fica a ~300 km (-9.76,-66.61), fora do perímetro urbano |

**Causa:** zonas digitadas à mão para dar "cara de mapa de calor", sem geocodificação nem vínculo com pedidos reais.
**Impacto:** o motorista decide para onde ir com base em demanda falsa; e o app exibe lugares que não existem naquele ponto — o problema que o prompt manda eliminar.
**Solução:** calor derivado de `rides`/ofertas reais por célula H3 e janela de 15 min; rótulos vindos de geocodificação (bairro oficial) ou nenhum rótulo; enquanto não houver volume, **não exibir mapa de calor** (mostrar "sem dados suficientes" é melhor que inventar).

### F-07 · A — A tarifa não é o motor documentado
**Evidência:** `demo_api.py:337-360`. Comparação com `docs/fase2/SPECS.md` §2:

| Componente da SPECS | Existe? | Onde/observação |
|---|---|---|
| `piso` da cidade | **não** | tarifa pode cair a R$ 4,59 (100 m, madrugada, zona fria) |
| `t_km` | sim (2,20) | mas hardcoded, não em `city_configs` |
| `t_min` | **não** | duração da rota é ignorada |
| espera no embarque | **não** | — |
| taxas | **não** | — |
| multiplicador por demanda (H3, razão pedidos/oferta, clamp 1,8, suavização) | **não** | peso fixo da zona + 0,07 por chamada nos últimos 15 min |
| multiplicador por hora | sim | 1,18 rush / 0,88 madrugada (não previsto na SPECS) |
| `city_configs` versionado | **não** | tabela existe (`0001_schema.sql:73-91`), sem seed e sem leitura |
| `fn_price_simulate` | **não** | — |

Tarifas calculadas com a fórmula atual (zona Centro, demanda 1,33):

| Distância | Fora do rush | Rush |
|---|---|---|
| 0,1 km | R$ 6,94 | R$ 8,19 |
| 0,5 km | R$ 8,11 | R$ 9,57 |
| 2 km | R$ 12,50 | R$ 14,75 |
| 5,3 km | R$ 22,16 | R$ 26,15 |
| 10 km | R$ 35,91 | R$ 42,37 |
| 20 km | R$ 65,17 | R$ 76,90 |

**Causa:** a demo precisava de um número que mudasse com demanda/hora; a política tarifária completa nunca foi codificada.
**Impacto:** não há como comparar com concorrentes, garantir margem, proteger o motorista nem impedir corrida deficitária — que é o núcleo da Fase 3 do prompt.
**Solução:** motor puro parametrizado por `city_configs` (base, km, min, piso, espera, taxas, clamp, arredondamento), cálculo por rota + duração, simulador chamando a **mesma** função, e vigência versionada com aprovação.

### F-08 · A — O piso da negociação é um número solto e contradiz o contrato
**Evidência:** `demo_api.py:493` — `if amount < 15`; `destino_screen.dart:356` (helper) promete "entre 70% e 300%"; `SPECS.md` §3 define 0,7× a 3× a tarifa, com rodadas e expiração.
Teste ao vivo: corrida com tarifa congelada de **R$ 10,00** → proposta de **R$ 8,00** (80%) recusada com `422 below_floor`; proposta de **R$ 15,00** (150%) aceita.
**Causa:** piso fixo de demonstração, sem referência à tarifa.
**Impacto:** bloqueia propostas válidas em corridas baratas e aceita ágio de 50% sem regra; a UI mente sobre o intervalo.
**Solução:** validar `0,7 × tarifa ≤ valor ≤ 3 × tarifa` no servidor, com piso de cidade configurável, rodadas/expiração e anti-colusão.

### F-09 · C — O cliente escolhe o preço
> **Fechado na demo em 07/11/2026** (o backend real da Fase 2 ainda precisa
> persistir/assinar a cotação). O `scripts/demo_api.py` hoje emite
> `quote_id` no `GET /quote` e cobra no `POST /rides` o valor gravado no
> servidor — uso único, validade de 90 s, vinculada à rota; o `quoted_fare`
> do corpo é informativo e, se divergir, o pedido é recusado (422
> `quote_fare_mismatch`). Ver `docs/REVISAO-FABLE.md` §5 e os 9 testes de
> `scripts/test_quotes.py`.

**Evidência (estado em 23/10):** `demo_api.py:443-448` — `quoted_fare` do corpo vira `fare_total`; `docs/fase2/openapi.yaml:750-757`; `docs/REVISAO-FABLE.md` já registrava a pendência "congelar a cotação no servidor".
**Causa:** a cotação é um número sem identidade; não há `quote_id`, assinatura ou janela validada.
**Impacto:** qualquer cliente altera o valor da corrida, do recibo e do lançamento na carteira; a "tarifa aprovada" deixa de ser garantia.
**Solução:** `GET /quote` devolve `quote_id` + validade; `POST /rides` referencia o id e o servidor recalcula/assina (rejeita adulteração e cotação vencida). Nunca confiar em valor do cliente.

### F-10 · A — Não existe registro de visualização/entrega da chamada
**Evidência:** `0001_schema.sql:267-281` — `offers.status` só tem `SENT/ACCEPTED/DECLINED/EXPIRED/REASSIGNED`, sem `viewed_at`, `delivered_at` ou tabela de eventos; busca por "viewed/delivered/notified" nos SQL e no OpenAPI retorna **zero** ocorrências.
**Causa:** o modelo da Fase 2 parou no "enviado".
**Impacto:** o contador "3 motoristas visualizaram sua chamada" não tem de onde sair; contar ofertas enviadas seria mentira.
**Solução:** `offers` ganha `delivered_at` e `viewed_at` (ou tabela `offer_events` idempotente `offer_id+partner_id+type`), endpoint de "assumi a visualização" autenticado pelo parceiro, agregação no `GET /rides/{id}` e push de atualização ao passageiro.

### F-11 · A — O despacho da SPECS não existe
**Evidência:** `demo_api.py:736-810` — gera oferta para qualquer corrida `BUSCANDO`, sem consultar posição, raio, KYC, heartbeat, score ou leva; `pickup_km = 1.2` fixo (`:774`); `amount` cai em `18.50` se faltar (`:758`); `destination_area` é o primeiro pedaço do endereço ou "Centro" (`:782`); todas as ofertas vão para o único parceiro demo.
**Causa:** com um parceiro só, o algoritmo não era necessário para o fluxo "funcionar".
**Impacto:** não há expansão de raio, nem N=3, nem exclusão de recusados, nem serialização do vencedor; a distância de coleta mostrada ao motorista é decorativa.
**Solução:** função de despacho por rodada (SQL/Edge Function) com `ST_DWithin`, frescor de heartbeat, score neutro ao modo, leva de 3, `FOR UPDATE` no aceite, reoferta por rodada e encerramento no aceite/cancelamento.

### F-12 · A — Não há tempo real
**Evidência:** `ride_controller.dart:174-210` e `partner_controller.dart:277-315` — timers de 5 s com backoff; nenhum cliente Realtime; `demo_api.py` não tem canal de eventos.
**Causa:** Realtime estava previsto como primário, mas nunca foi ligado.
**Impacto:** p95 de matching e de mudança de fase depende do poll; oferta de 15 s pode ser vista tarde; o contador de visualizações não teria como atualizar "sem recarregar".
**Solução:** canal autenticado por corrida/oferta (Supabase Realtime ou WebSocket próprio), com poll como fallback — como a arquitetura já prevê.

### F-13 · A — Não há região de operação aplicada
**Evidência:** `0001_schema.sql:55-63` (`cities.boundary geography(Polygon)`) sem seed; `POST /rides` aceita qualquer lat/lon; `_geocode` usa apenas uma `viewbox` retangular (`demo_api.py:1011-1015`), não o polígono urbano.
**Causa:** a geofence ficou no modelo, não na validação.
**Impacto:** corridas e endereços fora da praça entram; o caso "Nova Califórnia" (distrito a 300 km) ilustra o risco de confundir município com perímetro urbano.
**Solução:** polígono versionado por cidade, validação em `quote`, `rides` e despacho, e recusa explícita `out_of_area` com mensagem útil.

### F-14 · M — Serviços públicos de mapa no caminho de produção
**Evidência:** `route_service.dart:47` (OSRM demo), `city_map.dart:59`, `heatmap_map.dart:92`, `route_map.dart:137`, `fila_screen.dart:130` (tiles OSM), `demo_api.py:999-1030` (Nominatim). O documento mestre já registra que o servidor público de tiles é proibido em produção e que só lat/long são cacheáveis.
**Causa:** escolha pragmática para a demo sem chave.
**Impacto:** bloqueio por uso abusivo, ausência de SLA, e (no caso OSM) obrigação de atribuição/share-alike.
**Solução:** decidir provider (Google × OSM auto-hospedado × terceiro), centralizar atrás do `MapProvider`/serviço próprio, cache conforme política, atribuição correta e limites de requisição.

### F-15 · M — Autenticação é um placeholder
**Evidência:** `main.dart:36-40` dos dois apps — token vem de `--dart-define`, vazio por padrão; telas de login são locais; demo aceita tudo.
**Causa:** auth real estava prevista para o backend.
**Impacto:** não há como impedir que um cliente leia/altere corrida de outro, nem validar quem visualizou a oferta (requisito do contador).
**Solução:** JWT do provedor escolhido, `sub` como identidade no servidor, RLS nas tabelas e checagem de dono em toda rota.

### F-16 · M — Taxonomia de serviço divergente
**Evidência:** `0001_schema.sql:65-71` usa `RIDE_CAR`/`DELIVERY_MOTO`; `docs/fase2/openapi.yaml:853` e o app usam `MOTO`/`MOTO_NEGOCIA` (`configurar_solicitacoes_screen.dart:109-123`).
**Impacto:** o filtro de "Configurar solicitações" não mapeia para o banco; ofertas de carro nunca chegam (ou chegam por engano).
**Solução:** unificar o enum no contrato e migrar o DDL (ou um mapeamento explícito e testado).

### F-17 · B — URL padrão da API não casa com a demo
**Evidência:** `main.dart:37` — default `http://10.0.2.2:8787/functions/v1/v1`; a demo serve na raiz; o E2E contorna com `--dart-define` (`e2e_emulator.py:995`).
**Impacto:** `flutter run` sem define resulta em 404 e parece "app quebrado".
**Solução:** default coerente com o ambiente de desenvolvimento (ou falha explícita pedindo `API_BASE`).

### F-18 · B — Os testes não cobrem nada do que este prompt pede
**Evidência:** `app/passageiro/test` (4 arquivos, 28 testes) e `app/parceiro/test` (2 arquivos, 22 testes) usam cliente HTTP falso; não há teste de radar, despacho, tarifa, geofence, contagem de visualização ou estados de oferta.
**Impacto:** os defeitos acima passam verdes.
**Solução:** pirâmide da Fase 7: testes puros do motor de preço e do score, testes de API com banco real (Testcontainers/Docker), testes de widget dos 8 estados do radar e testes de concorrência do aceite.

### F-19 · B — O teclado empurra a cotação para fora da tela (achado em 11/11/2026)
**Evidência:** `destino_screen.dart` — ao confirmar o número do endereço, o teclado continuava aberto; com o teclado a tela perde ~40% da altura e o card "Valor da corrida" (com o preço e o CTA "Chamar") sai da área visível. Prova: `.preview/e2e_auto/20261111-012937-a1/failure-sem-cotacao.png` (o `uiautomator`, que só enxerga o que está na tela, não achava o preço) contra `20261111-020938-a1/02b-passageiro-radar.png` (sem teclado, o formulário inteiro cabe).
**Impacto:** o passageiro pode **chamar sem ver o preço** — e o E2E lia "não encontrei a cotação" como se fosse defeito do produto, quando era de tela.
**Solução:** **fechada** — o endereço completo fecha o teclado (`FocusScope.unfocus` em `_pick`), com teste de regressão C10; o harness também confere e fecha o teclado antes de ler o preço (`Ui.dismiss_keyboard`, que só manda BACK se o IME estiver aberto — BACK cego voltaria a rota).

---

## 4. Verificação da contagem de motoristas (item 5)

O prompt pede que a quantidade exibida corresponda a motoristas realmente conectados e elegíveis. A cadeia de estados necessária é:

```
disponíveis na região → elegíveis → chamadas enviadas → notificadas → visualizadas → recusadas → aceitas
```

Hoje:

| Elo | Existe? | Evidência |
|---|---|---|
| disponíveis na região | **não** | `/partners/nearby` sintetiza 3; `partner_presence` nunca é lida |
| elegíveis (KYC, raio, frescor, tipo) | **não** | nenhum filtro; `openapi.yaml` descreve, servidor não implementa |
| chamadas enviadas | parcial | `offers` em memória, sem distinção por parceiro real |
| notificadas | **não** | sem push, sem `delivered_at` |
| visualizadas | **não** | sem `viewed_at` e sem endpoint de evento |
| recusadas / aceitas | sim (demo) | `POST /offers/{id}/decline` e `/accept` |
| contador na tela do passageiro | **não existe** | nenhuma ocorrência de contador em `app/passageiro` |

**Resposta direta:** a quantidade exibida hoje **não** corresponde a ninguém conectado; ela é fabricada. E não há contador de visualizações porque o modelo de dados não registra visualização. Não é um bug de tela — é uma peça ausente do domínio.

---

## 5. Inventário de dados fictícios (item 4)

| Dado | Valor | Arquivo |
|---|---|---|
| Origem do passageiro | `-8.7607, -63.9039` fixo | `destino_screen.dart:33-34`, `fila_screen.dart:28`, `city_map.dart:24` |
| Endereço de embarque | `"Centro, Porto Velho - RO"` literal | `destino_screen.dart:191` |
| Destino fallback | `-8.7647, -63.8969` | `destino_screen.dart:36` |
| Posição do motorista online | `-8.7607, -63.9039` | `painel_screen.dart:494` |
| Motoristas do radar | `demo-driver-0..2`, offsets fixos, sempre `available` | `demo_api.py:868-874` |
| Veículo dos motoristas | `"Honda Biz 125"` para todos | `demo_api.py:872` |
| Motorista que aceita sozinho | `"Seu Raimundo (simulado)"` em 12 s | `demo_api.py:168,211-212,233-234` |
| Nome do passageiro na oferta | `"Passageira demo"` | `demo_api.py:788` |
| Distância de coleta | `1.2 km` (e ETA derivado) | `demo_api.py:774` |
| Área de destino | primeiro pedaço do endereço ou `"Centro"` | `demo_api.py:782` |
| Valor de oferta fallback | `18.50` | `demo_api.py:758` |
| Distância de viagem fallback | `4.8 km` | `demo_api.py:766` |
| Bairros do calor | 7 rótulos errados/inventados | `demo_api.py:148-165` |
| Chamadas/hora por zona | 38, 31, 24, 18, 12, 9, 5 | `demo_api.py:149-164` |
| Tarifas | `5,00 + 2,20×km` com multiplicadores fixos | `demo_api.py:337-360` |
| Piso de negociação | `R$ 15,00` literal | `demo_api.py:493` |
| Pix de demonstração | QR `data:image/png;base64,demo` e copia-e-cola fake | `demo_api.py:900, :933` |
| Tarifa de aprovação | `R$ 10,00`/12h (correto como parâmetro, mas sem `city_configs`) | `demo_api.py` (estado) |

Nem todo item acima é erro: fallback de rede é legítimo **quando rotulado** ("rota aproximada"). O problema é usar fallback como se fosse dado real, ou usá-lo como fonte primária.

---

## 6. O que é real e deve ser preservado

- **Tiles e ruas reais:** os prints do emulador mostram Centro, Arigolândia, São Cristóvão — o mapa não é desenho.
- **Geocoding real:** "Porto Velho Shopping, 3288, Avenida Prefeito Chiquilito Erse…" veio do Nominatim e existe.
- **Rota real:** OSRM devolveu 5,3 km · 8 min para o trajeto do print; a cotação usa o mesmo km do recibo (cadeia verificada em `REVISAO-FABLE.md`).
- **Contrato e DDL:** são ativos valiosos — RLS, ledger de partida dobrada, máquina de estados, idempotência. Devem ser a base do servidor, não descartados.
- **Apps:** 28 + 22 testes verdes, `dart analyze` limpo, fluxo C1→C11/P1–P7 navegável, tema claro funcionando.

---

## 7. Verificação executada nesta fase

| Verificação | Comando | Resultado |
|---|---|---|
| Análise estática passageiro | `dart analyze lib test` | **0 issues** |
| Testes passageiro | `flutter test` | **28/28** |
| Análise estática parceiro | `dart analyze lib test` | **0 issues** |
| Testes parceiro | `flutter test` | **22/22** |
| `flutter analyze` | — | **quebra** neste path (`FormatException` no LSP por causa do "é" em `10é+`, exit 255); não é lint — usar `dart analyze` |
| Sem auth na demo | `curl -i /me` sem token | **200 OK** |
| Motoristas sintéticos | `GET /partners/nearby` | 3 objetos `demo-driver-*`, `available: true` |
| Cotação ao vivo | `GET /quote` (Centro → KM-1) | `R$ 11,99` · 1,2 km · demanda 1,33 · hora 1,18 |
| Piso de negociação | `POST /rides` (tarifa 10) + `negotiation` | 8,00 → **422 below_floor**; 15,00 → **200** |
| Rótulos do calor | geocodificação reversa de 7 coordenadas | 6 de 7 **não** correspondem ao rótulo |
| Aeroporto real | geocodificação direta | `-8.7098, -63.9010` (6 km da zona "Aeroporto") |
| Nova Califórnia | geocodificação direta | `-9.7651, -66.6172` (fora do perímetro urbano) |

Não executei o E2E de emulador nesta rodada (é a etapa da Fase 7); o verde de referência continua sendo `.preview/e2e_final_hoje/20261023-095842-a1` e o workflow `e2e-emulator`.

---

## 8. Plano proposto (para aprovação)

### 8.1 Ordem que eu recomendo

| Etapa | Conteúdo | Depende de | Esforço (estimativa) |
|---|---|---|---|
| **A. Base real** | Subir Postgres + Edge Functions do contrato; auth JWT; presença (`partner_presence`) com heartbeat e posição reais; geofence; CI com banco | decisão de backend (§9) | M-G |
| **B. Radar** | Captura de GPS nos dois apps; `/partners/nearby` real e aproximado; radar animado com 8 estados; despacho por rodada (raio, score, N=3, `FOR UPDATE`); fim do simulador por padrão | A | M-G |
| **C. Preço** | Motor parametrizado (`city_configs`); piso, km, min, espera, taxas; multiplicador H3 com clamp/suavização; `quote_id` assinado; simulador com a mesma função; estudo de mercado com fontes | A + dados de concorrentes | M |
| **D. Mapa** | Polígono de operação; remover zonas fabricadas; calor por demanda real; rótulos geocodificados; decisão de provider | A | P-M |
| **E. Contador** | `offers.viewed_at`/`offer_events`; endpoint autenticado; agregação + push; UI "N visualizaram" com estados de indisponível | A + B | P-M |
| **F. Testes** | Propriedades do preço/score, concorrência de aceite, frescor, geofence, 8 estados do radar, dois usuários isolados, sem dados fictícios | A–E | M |

P = pequeno, M = médio, G = grande (relativo a este repositório; não é prazo de calendário).

**Referência visual do radar (imagem anexada):** a captura do app da 99 mostra o padrão que o prompt descreve — fundo escuro, ondas concêntricas, cone de varredura, ponto central e a mensagem de espera. Vou seguir essa estrutura, mas com os tokens do tema claro/teal do 10 é + (contraste AA, sem depender de fundo escuro), e com os estados e o contador vindos do servidor — não uma animação decorativa.

### 8.2 O que **não** recomendo
- Continuar evoluindo a demo em memória como se fosse backend: cada fase nova (contador, geofence, tarifa versionada, visualização) exige persistência e autenticação; remendar a demo acumula dívida e mantém os dados falsos.
- Reduzir preço "no olho" antes do estudo de mercado e do simulador (o prompt proíbe, e a margem do passe é apertada).
- Exibir contador de visualizações baseado em "ofertas enviadas": seria repetir o erro do radar.

### 8.3 Riscos e limites
- **Provider de mapas:** custo e termos (Google × OSM). A decisão muda o orçamento mensal e o esforço operacional; não dá para adiar muito porque o GPS e o despacho dependem da distância/ETA.
- **Emulador intermitente:** o E2E de UI neste host já falha por infra; o verde confiável é o CI. Não vou declarar fluxo validado sem `result.json` de PASS.
- **Tail do PostGIS/Realtime:** o throughput de posições precisa de teste de carga antes de prometer p95; o documento já registra RSK-007.
- **Regulatório:** KYC/alvará (SEMTRAN) continua bloqueio externo e não é resolvido por código.

---

## 9. Decisões que preciso de você (GATE 1)

1. **Backend alvo** — implementar o servidor do contrato (Supabase local + Edge Functions + Postgres/PostGIS) ou continuar sobre `demo_api.py`? A primeira opção é a única que sustenta radar real, contador e tarifa versionada; a segunda é mais rápida, mas mantém os dados fictícios e não tem auth/RLS.
2. **Provider de mapas** — Google (padrão R1, custo estimado já levantado) × OSM auto-hospedado (barato, exige operação) × manter serviços públicos apenas em desenvolvimento e decidir o provider antes de publicar.
3. **Política do simulador** — manter o auto-aceite apenas com `DEMO_MODE=1` e etiqueta visível (recomendado) ou removê-lo de vez.

Com essas três respostas eu fecho o escopo da próxima fase e começo pela base real + radar, sem tocar em preço até você aprovar os cenários.

---

## 10. Como reproduzir este diagnóstico

```bash
python scripts/demo_api.py --port 8799

curl -s "http://127.0.0.1:8799/partners/nearby?lat=-8.7607&lon=-63.9039"
curl -s "http://127.0.0.1:8799/quote?origin_lat=-8.7607&origin_lon=-63.9039&dest_lat=-8.7647&dest_lon=-63.8969"
curl -s -i "http://127.0.0.1:8799/me" | head -3          # 200 sem token

cd app/passageiro && dart analyze lib test && flutter test
cd app/parceiro   && dart analyze lib test && flutter test
```

Geocodificação reversa usada na §3/F-06 (Nominatim, uma consulta por segundo, `User-Agent` identificado).
