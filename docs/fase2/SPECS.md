# 10 é + — Specs algorítmicas (Fase 2, Parte 4/5)

Todas as funções abaixo são puras/testáveis e parametrizadas por `city_configs` (T7). Nenhum valor é hardcoded.

## 1. Despacho (matching) — Edge Function `dispatch`

### 1.1 Rodadas de despacho

A cada corrida em `BUSCANDO`, o dispatch executa rodadas até `rmax`:

```
R(0) = PRM-match.r0 (2 km); R(n+1) = R(n) + PRM-match.passo (1 km) ≤ PRM-match.rmax (8 km)
timeout de rodada = PRM-oferta.timeout (15 s)
```

**A janela da oferta é um parâmetro por cidade, e a cidade piloto está
trancada no valor do contrato.** O valor effective sai de
`city_param(city_id, 'PRM-oferta.timeout', '15')` — ou seja, uma config
divergente muda o tempo de espera do passageiro **sem aparecer no código**.
Por isso o banco agora recusa, na hora de gravar, qualquer janela fora do
contrato na cidade piloto (15 s) e fora da faixa combinada nas outras praças
(10..60 s) — trigger `trg_city_config_window`
(`supabase/migrations/20261110000400_oferta_timeout_contrato.sql`).

> **O que aconteceu (10/11/2026):** o banco local tinha a janela em **60 s**
> (desvio de uma seeding antiga que o `WHERE NOT EXISTS` do seed nunca
> reconciliou) enquanto o SPEC, o `seed.sql` e a API de demonstração diziam
> 15 s. O passageiro esperava 4× mais por um motorista que talvez nunca
> visse a oferta. Agora o valor vive em `scripts/contract.py` (fonte única),
> o seed reconcilia, o banco trava e o E2E confere a janela **no servidor**
> (`timeout_at - sent_at`).

Candidatos (SQL, indexado por GiST em `partner_presence.last_position`):

```sql
SELECT p.user_id, pr.last_position, p.rating_avg, p.acceptance_rate, pr.last_heartbeat_at
  FROM partners p JOIN partner_presence pr ON pr.partner_user_id = p.user_id
 WHERE p.city_id = @city AND p.kyc_status = 'APPROVED' AND p.deleted_at IS NULL
   AND pr.online_status = 'ONLINE_DISPONIVEL'
   AND ST_DWithin(pr.last_position, @origin, @radius_m)
   AND pr.last_heartbeat_at > now() - interval '90 seconds'   -- PRM-hb.intervalo+grace
```

### 1.2 Estratégia de oferta: **leva simultânea limitada (N=3)**

| Opção | Prós | Contras | Veredito |
|---|---|---|---|
| Sequencial 1 a 1 | Sem corrida fantasma | p95 = N×15 s (3 parceiros = 45 s > SLO 10 s) | Descartada |
| Broadcast irrestrito | Velocidade | Várias aceitações simultâneas, anti-starvation ruim, ruído | Descartada |
| **Leva de N=3 melhores** | p95 ≤ 15 s; 1 vencedor via `FOR UPDATE` | ~2 avisos "já tomada" por corrida | **Escolhida** |

Na rodada: ordenar por score, ofertar aos 3 primeiros (`fn_dispatch_offer` × 3); o `fn_offer_accept` serializa por `FOR UPDATE` na corrida — o primeiro vence, os demais recebem `offer_unavailable`.

> **Implementado hoje (`scripts/dispatch.py` + `scripts/demo_api.py`): oferta sequencial.**
> Decisão de produto do dono do app: o melhor recebe primeiro, recusa/timeout de
> 15 s → próximo da lista, até esgotar o raio (2 → 8 km). A leva de 3 continua
> sendo o alvo do Edge Function em produção para caber no SLO de 10 s; o score,
> os filtros e a reoferta são os mesmos nos dois modos, então a troca é só no
> número de ofertas simultâneas.

### 1.3 Score (neutralidade ao modo: SEM `monetization_mode` na fórmula — auditoria obrigatória)

```
score = w1·f(ETA) + w2·f(rating) + w3·f(aceitação) + w4·f(ociosidade) + w5·f(rota)
pesos iniciais: w1=0.40, w2=0.20, w3=0.15, w4=0.15, w5=0.10  [calibrar com dados]
```

Normalização (todas as entradas em [0,1], quanto maior melhor):
- `f(ETA) = 1 − clamp(eta_min / 15, 0, 1)` — **alavanca L2 (GATE 2):** ETA estimado localmente (distância retilínea ÷ velocidade média da praça), **não** o provedor de rotas — 4,4 eventos Google/ride economizados sem tocar na neutralidade ao modo. Em staging, comparar com provedor: se o ranqueamento divergir > 10% dos top-3, revisar.
- `f(rating) = clamp((rating_avg − 3.5) / 1.5, 0, 1)` — só星光 com n ≥ 20 conta; abaixo disso 0.7 (neutro).
- `f(aceitação) = acceptance_rate` (janela 30 d).
- `f(ociosidade) = clamp(segundos_ocioso / 1800, 0, 1)` — **anti-starvation**: quem está parado há mais de 30 min pesa máximo; é a variável de justiça.
- `f(rota) = 1 − desvio_do_caminho / 2000 m` — qualidade da posição (desvio da rota direta).

Desempate: maior `f(ociosidade)`, depois menor ETA. Reoferta: a cada rodada exclui os já ofertados; 3 rodadas sem aceite → nova rodada com todos elegíveis (penalização suave por recusa sistemática = reduzir `f(aceitação)`; **nunca** exclução total).

> **Timeout conta como recusa (soft).** Deixar os 15 s estourarem aplica a mesma
> redução de 3% na `acceptance_rate` do parceiro — senão ignorar a oferta sairia
> mais barato do que apertar "Recusar". Todo fechamento (`DECLINED`/`EXPIRED`)
> grava o que o parceiro deixou passar — valor congelado, coleta, corrida e a
> taxa de aceite antes/depois (`OfferLoss` no contrato) — e o app P3 mostra esse
> resumo ao motorista antes de voltar ao painel, para a consequência não ser
> invisível.

### 1.4 Entregas (MVP-B)

Mesmo algoritmo; candidatos filtrados por `service_type` compatível e `vehicles.category`; raio inicial menor (3 km) por coleta; `batching` opcional: aceitar 2ª coleta se desvio ≤ 30% e destino a ≤ 2 km do primeiro destino.

### 1.5 Presença viva — o app do parceiro tem de continuar rodando

O despacho só considera `last_heartbeat_at > now() - 90 s` (§1.1). Logo, **enquanto
o parceiro está ONLINE, o app precisa continuar vivos** — não basta publicar a
presença uma vez ao ficar online.

| Camada | Regra |
|---|---|
| App | Heartbeat a cada **30 s** (`PRM-hb.intervalo`), publicando status + posição (`POST /radar/presence`). Folga: 3 batidas dentro da janela de 90 s. |
| App | Ao voltar do segundo plano, **republica** a presença na hora (o app pode ter sido congelado e a presença ter vencido). |
| Android | App em **primeiro plano** (`PresenceService`, tipo `location`) enquanto ONLINE: sem isso o sistema congela o processo em cache e o heartbeat para — o parceiro some do radar **sem aviso no painel**. |
| Servidor | `stale_after = heartbeat + 90 s`: a presença expira sozinha se o app morrer (o estado nunca é "online eterno"). |

> **Por que o serviço em primeiro plano e não só um timer:** medido no emulador
> (10/11/2026), com o app do parceiro em segundo plano o Android suspendeu os
> timers do Dart por ~1 min (o poll de ofertas parou 21:36:10 → 21:37:09 UTC) e
> o passageiro, que só buscou 2 min depois, viu **0 motoristas** — com o
> parceiro "online" no painel. O serviço em primeiro plano impede o
> congelamento; o `START_NOT_STICKY` garante que a notificação "Você está
> online" nunca sobreviva ao processo que a publicava.

## 2. Motor de preço

```
tarifa = max(piso, base + km·t_km + min·t_min + espera + extras) × multiplicador + taxas
```

- Todos os componentes em `city_configs` por cidade × service_type (ex.: `PRM-preco.base`, `.t_km`, `.t_min`, `.espera_min`, `.piso`).
- `espera`: minutos de espera do passageiro no embarque após CHEGOU (> 3 min) × tarifa de espera.
- **Multiplicador de demanda** (por célula H3 res 9, janela 15 min):

```
razão = demanda (pedidos abertos na célula) / oferta (parceiros ONLINE_DISPONIVEL na célula+vizinhança)
m = clamp(1 + 0.25 × (razão − 1), 1.0, PRM-preco.m_max (1.8))   # linear amortecida
suavização: m_efetivo = 0.7 × m_anterior + 0.3 × m   (evita oscilação 1.0→1.8→1.0)
```

- Transparência: a UI exibe "tarifa com aumento de demanda: R$ X" quando `m > 1.15`; nunca "surge" oculto.
- Piso/repasse do passageiro que negocia: proposta mínima sugerida = `0.7 × tarifa` (configurável), abaixo disso a API responde `422 below_floor`.
- **Entregas (REQ-004, interpretação A aprovada):** `piso = PRM-entrega.piso (R$ 8,00)`; a estratégia B (faixa diferenciada acima de R$ 8) existe como `PRM-entrega.regime ∈ {PISO, FAIXA}` — mesma fórmula com `faixas` de km/troca.
- **Nunca cobra:** corrida cancelada, falha do sistema, viagem de teste (`PRM-teste.numeros`).
- Simulador: função SQL pura `fn_price_simulate(city, km, min, wait_min, surge, regime)` usada pelo console (K5) antes de publicar vigência — mesma implementação do cálculo real.

## 3. Negociação (D2)

- Passageiro propõe (`PROPOSE`): valor ≥ `0.7 × tarifa` e ≤ `3 × tarifa`; rate limit: 3 negociações abertas/h (`PRM-neg.max_h`).
- Parceiro vê a proposta como oferta com `offered_amount` do proposto; pode **aceitar** ou **contrapropor** (`COUNTER`, ≥ piso); máx. 3 rounds; cada round expira em 60 s (`PRM-neg.round_ttl`).
- Expiração sem aceite → corrida volta a `BUSCANDO` em modo tarifa (o passageiro pode pedir pela tarifa cheia).
- **Anti-colusão:** par (passageiro, parceiro) com ≥ 3 corridas negociadas em 24 h → bloqueio temporário de negociação entre eles + flag de revisão (nunca despacho penalizado).
- **Anti-dumping:** preço final negociado abaixo de `0.5 × tarifa` → marcado para auditoria amostral; passageiro com 5+ cancelamentos em 7 d não abre negociação (usa tarifa).

## 4. ETA e recálculo

- Base: provedor de rotas (R1) com tráfego quando disponível; **servidor calcula sempre** (o passageiro nunca calcula ETA do parceiro).
- Correção estatística local: `eta_final = eta_base × p95_ratio(trecho)` com histórico por origem×destino (aprende atrasos reais de Porto Velho); inicializa em 1.0.
- **Recálculo sob demanda** (nunca polling 15 s — armadilha de custo US$ 15k/mês): (a) virada de rota detectada (≥ 15% de mudança no traçado), (b) a cada 90 s em viagem, (c) desvio > 200 m do traçado, (d) a cada nova fase (ACEITA→A_CAMINHO→CHEGOU).
  - **Alavanca L1 (GATE 2):** o gatilho (b) de 90 s usa **modelo local** (distância restante ÷ velocidade observada do próprio GPS do parceiro); o provedor de rotas é chamado **só** em (a), (c) e (d). −10,7 eventos Google/ride. O `eta_final` continua passando pela correção `p95_ratio(trecho)` acima. Política Google 10/2026: conteúdo de rota não é cacheável (só lat/long 30 d) — por isso a ETA local não deriva de nada armazenado do Google.
- GPS ruim: snap-to-road no servidor (PostGIS `ST_ClosestPoint` em ways) + descarte de outliers (velocidade > 130 km/h ou salto > 500 m em < 5 s); `stale_after` na presença expõe a frescor à UI.
- Alarme ≤ 4 min (REQ-008): o servidor avalia o cross do threshold a cada atualização de ETA; dispara **1 evento idempotente por corrida** com histerese (re-arm só se ETA > 360 s).

## 5. Invariantes auditáveis (QA)

1. Score do despacho não contém `monetization_mode` (teste estático no CI: grep no código + simulação com parceiros idênticos em modos distintos → distribuição igual).
2. `multiplicador` sempre dentro dos limites da cidade (property test).
3. Toda cobrança passa por `max(piso, ...)`; nenhuma corrida concluída < piso (exceto teste).
4. ETA é monotônico para a mesma fase (não "anda para trás" sem mudança de rota > limiar).
5. **Presença viva (§1.5):** com o parceiro ONLINE, a idade do heartbeat no
   Postgres é `< 90 s` — verificado pelo E2E antes do passageiro pedir a
   corrida, e o passageiro tem de ver **"N motoristas na região"** (contador
   positivo), nunca "Nenhum motorista". A conferência acontece na
   tela de **destino**, antes do pedido: a oferta do parceiro vive 15 s
   (§1.1) e uma leitura de tela no emulador custa 3-5 s — medir dentro da
   janela produzia falso negativo de infraestrutura, não de produto. O
   contador é o mesmo dado (presença real no Postgres) e **viaja com o
   pedido** para a tela de busca, que abre já com o número na tela.
6. **Janela da oferta (§1.1):** `offers.timeout_at - offers.sent_at` é
   **15 s** na cidade piloto — conferido no servidor pelo E2E (não no
   relógio do cliente) e travado no banco (trigger
   `trg_city_config_window`). O mesmo valor vive em `scripts/contract.py`
   (`OFERTA_TIMEOUT_S`) e é conferido contra o SQL e o SPEC por
   `scripts/test_contract.py`.

## 6. KYC do parceiro — fila, SLA e decisão (Edge Function `kyc`)

O KYC é regra do **servidor**: quem decide é o Postgres
(`api_kyc_case_create`, `api_kyc_case_get`, `api_kyc_case_document`,
`api_kyc_queue`, `api_kyc_review` —
`supabase/migrations/20261110000500_kyc_api.sql`). A Edge Function `kyc` é
uma fachada fina que repassa o `Authorization` do chamador: o ator é
`auth.uid()`, nunca um id do corpo. Nenhum número deste bloco está no
código — tudo vem de `city_configs` (T7).

### 6.1 O caso e a fila

- `POST /kyc/cases` abre (ou retoma) o caso do parceiro. Quem já tem um caso
  em aberto (`IN_REVIEW`, `RESUBMIT`, `REJECTED`) recebe o **mesmo** caso: um
  duplo toque no botão não cria duas filas. A mesma `Idempotency-Key` devolve
  a resposta original (`Idempotency-Replayed: true`).
- A fila é ordenada por `(sla_due_at, created_at, id)`; a **posição** que o
  app mostra é o rank do caso nessa ordem (1 = o próximo a ser analisado).
- Só o papel **AGENT/ADMIN** vê a fila (`GET /kyc/queue`) e decide
  (`POST /kyc/cases/{caseId}/review`). O parceiro enxerga apenas o caso dele
  (`GET /kyc/cases/{caseId}`) — caso alheio é 403, sempre.

### 6.2 O SLA é uma promessa de atendimento, não um temporizador

```
prazo = primeiro instante ≥ (agora + PRM-kyc.sla_antecedencia_h)
        que cai dentro da janela humana
        [PRM-kyc.review_inicio_h .. PRM-kyc.review_fim_h]   (fuso da praça)
```

- Cidade piloto: janela humana **7h–23h**, antecedência mínima **2 h**
  (`scripts/contract.py`: `KYC_REVIEW_START_H`, `KYC_REVIEW_END_H`,
  `KYC_SLA_LEAD_H`).
- O relógio é o do **servidor**, no fuso da praça (`cities.timezone`).
- Prometer "2 h" às 23h30 — quando não há gente revisando — seria uma
  promessa falsa: o prazo cai na primeira abertura da janela seguinte que
  ainda cumpre a antecedência.

### 6.3 A decisão

- `APPROVED` (aprovado pela operação), `REJECTED` (recusado) ou `RESUBMIT`
  (a operação pede documento novo). O vocabulário do caso é o mesmo do
  parceiro (`partners.kyc_status`), para a fila manual ter destino.
- Recusa e pedido de reenvio exigem **`rejection_code`** (422
  `rejection_code_required`): sem o código padronizado, o parceiro não sabe
  o que corrigir.
- A decisão é o ato que muda o mundo: `partners.kyc_status` passa a valer
  (só `APPROVED` recebe oferta — §1.1), o rastro vai para `audit_log`
  (`KYC_DECIDED`), o parceiro é notificado (`IN_APP`, `KYC_DECIDED`) e o
  evento `kyc.decided` é emitido para o BI.
- O reenvio do parceiro (`POST /kyc/cases/{caseId}/documents`) devolve o
  caso para a fila como `RESUBMIT`, com prazo novo (o relógio andou desde a
  última promessa) e o motivo da recusa limpo — o histórico fica no
  `audit_log`.
- O vocabulário do motivo é **fechado** (`scripts/contract.py`:
  `KYC_REJECTION_CODES`): `CNH_ILEGIVEL`, `CNH_VENCIDA`, `DOC_INCOMPLETO`,
  `FOTO_INVALIDA`, `COMPROVANTE_INVALIDO`, `DADOS_DIVERGENTES`. A operação
  **escolhe** da lista (não digita) e o parceiro recebe o código que sabe
  corrigir.

### 6.4 O console da operação (`app/console`)

O console é a **superfície irmã** do passageiro e do parceiro: é onde a
pessoa da operação lê a fila, vê o prazo e decide (`docs/PRODUTO-MESTRE.md`,
Fase 3). Ele é um app Flutter mobile (Android/iOS), não uma página web.

- **Login**: e-mail → código de 6 dígitos, como os outros apps — mas o
  console **não cadastra conta** (`create_user: false`) e **não mexe no
  papel** (`withRole: false`): quem opera o cadastro entra com a conta que
  já existe. O papel vem do `users.role`, que só o trigger de identidade
  escreve.
- **Conferência de papel**: `GET /kyc/me` devolve `role` e `is_agent`. A tela
  recusa na hora quem não é AGENT/ADMIN e encerra a sessão — entrar
  "funcionando" e só falhar na fila seria pior do que não entrar.
- **Fila** (`GET /kyc/queue`): posição, prazo (SLA), tempo de espera,
  quantos documentos o caso tem e **quem é o parceiro** (`partner_name` de
  `profiles.full_name` e `partner_phone` de `users.phone_e164`). Sem o nome,
  a fila mostrava "Parceiro 77777777" — a operação não sabia de quem era o
  cadastro nem como falar com a pessoa. Os estados vazio (com ação de
  atualizar), de erro e de recusa de permissão são telas explícitas — nunca
  uma fila inventada. A fila **se atualiza sozinha** (polling de 30 s): uma
  fila parada, com a pessoa operando um caso, é uma fila mentirosa. Duas
  leituras que se cruzam não podem se atropelar: a fila só é reescrita por
  uma leitura **mais nova que a última que deu certo** — se a leitura nova
  **falhou** e a antiga deu certo, o último retrato verdadeiro continua na
  tela **com o aviso de erro** (trocar uma informação boa por uma tela
  vazia seria pior). O erro só some quando um sucesso **mais novo** chega.
  Toda leitura tem **prazo** (`ConsoleApi.requestTimeout`, 20 s): um
  servidor mudo vira o erro `offline`, nunca um spinner eterno. O spinner
  pertence à leitura mais recente: só ela desliga (uma leitura antiga que
  responde não pode piscar a tela).
  O servidor ordena a fila por `(sla_due_at, created_at, id)` **antes** do
  `LIMIT`: com `LIMIT` sem `ORDER BY`, o Postgres devolvia 50 casos
  arbitrários e o caso que vence primeiro podia não aparecer — esconder
  trabalho numa fila de atendimento. O CI prova isso **comportamentalmente**
  (mais de 50 casos na fila: o mais urgente tem que aparecer e em primeiro
  lugar), não só pelo texto da migration.
- **Detalhe** (`GET /kyc/cases/{caseId}`): a **identidade** do parceiro (nome,
  telefone e conta), a documentação com a marca de **arquivo pendente**
  (documento registrado sem arquivo) e a decisão (aprovar, recusar ou pedir
  reenvio) com a folha de motivo padronizado.
- **O documento é VISTO**: o detalhe devolve o `storage_path` dos documentos
  e a marca `has_file`. O console baixa o objeto do bucket privado **com o
  próprio token da operação** e mostra a imagem (miniatura no detalhe, tela
  cheia com zoom ao toque). A operação não aprova uma CNH que nunca viu.
- **`has_file` é HONESTO**: o campo pergunta ao **bucket** se o objeto
  existe (`fn_kyc_storage_object_present`), e não "o caminho não é o
  marcador `PENDENTE/`". Um `storage_path` que não aponta para objeto
  nenhum é `has_file: false` — e a tela mostra **SEM ARQUIVO**. A versão
  anterior calculava pelo nome do caminho: pintava **ARQUIVO OK** (verde) e
  o preview falhava logo abaixo, duas afirmações contrárias na mesma tela
  (`supabase/migrations/20261110000900_kyc_console_docs_fix.sql`). A função
  que pergunta ao bucket **não é pública**: `REVOKE … FROM PUBLIC, anon` +
  `GRANT … TO authenticated, service_role` (convenção da 00600) — sem isso
  ela virava um oráculo público de existência de documento num bucket
  privado.
- **O marcador legado volta como está**: um documento registrado **sem
  objeto** tem `storage_path` = `PENDENTE/<case>/<tipo>` (a coluna é
  `NOT NULL`) e `has_file: false`. O cliente **não** tenta baixar o
  marcador.
- **Campos nulos são OMITIDOS**: o detalhe é montado com
  `jsonb_strip_nulls`, então um campo nulo (`rejection_code`, `sla`,
  `partner_name`) **não vem** — não vem como `null`. O cliente trata
  "ausente" e "nulo" igual (`docs/fase2/openapi.yaml`, `KycCase`). A fila,
  ao contrário, **não** usa `jsonb_strip_nulls`: lá o nulo **vem** como
  `null` (`KycQueueItem.sla_due_at` é `nullable`).
- **Decisão** (`POST /kyc/cases/{caseId}/review`): as mesmas regras do
  servidor — recusa e reenvio exigem `rejection_code` (422
  `rejection_code_required`), e a decisão muda o mundo (§6.3).

### 6.5 O arquivo do documento (F9): bucket privado e upload real

A foto do documento **não passa pela API**: o app do parceiro sobe o arquivo
no **Storage privado** e a API só registra o caminho.

- **Bucket**: `kyc-docs`, **privado** (`public = false`) — nenhuma URL
  anônima entrega documento de parceiro (`supabase/migrations/20261110000600_kyc_storage.sql`).
- **Quem lê**: o dono da pasta (`storage.foldername(name)[2] = auth.uid()`)
  **e a operação** (`OR app_is_agent()` — `supabase/migrations/20261110000800_kyc_console_docs.sql`).
  A política não é "quem está logado": é o dono **ou** quem tem papel
  AGENT/ADMIN. Um parceiro logado **não** lê o documento de outro.
- **A operação baixa com o próprio token**: o console chama o REST do
  Storage (`GET /storage/v1/object/kyc-docs/<path>`) com o JWT da sessão —
  a RLS autoriza. Não há **service role** no caminho do produto nem URL
  assinada compartilhável (uma URL assinada vazia o documento para quem a
  recebe).
- **Caminho do objeto**: `kyc/<partner_user_id>/pending/<doc>_<ms>.jpg`. A
  segunda pasta é o **dono**: é dela que a RLS do bucket tira a conclusão de
  quem pode ler e escrever (`storage.foldername(name)[2] = auth.uid()`).
  O `pending` é a pasta de quem ainda não tem caso — o id do caso só existe
  depois de `POST /kyc/cases`, e o upload vem **antes** para a operação
  nunca ver um caso sem o documento que ele diz ter.
- **O servidor confere**: o path tem que ser do próprio parceiro (422
  `storage_path_not_owned`) e o objeto tem que **existir** no bucket (422
  `document_not_found`). Sem Storage no banco, a API degrada com 503
  `storage_unavailable` — em vez de estourar com "relation does not exist".
- **Sem arquivo, o registro é honesto**: o servidor grava
  `PENDENTE/<case>/<doc>` com `quality_flags.upload_pending = true`. O
  console mostra **ARQUIVO PENDENTE** antes de aprovar.
- **Qualidade da foto**: medida no cliente (Dart puro), em Dart: borrão pela
  variância do Laplaciano e reflexo pela fração de pixels estourados. Os
  limiares são contrato (`scripts/contract.py`: `KYC_BLUR_THRESHOLD`,
  `KYC_GLARE_RATIO_THRESHOLD`; espelhados em
  `app/parceiro/lib/src/media/document_quality.dart`). É **aviso**, não
  bloqueio: quem aprova é a pessoa da operação.

