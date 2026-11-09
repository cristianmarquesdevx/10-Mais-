# Revisão da Fase 3 + execução do fluxo passageiro ↔ parceiro

> Data: 22/10/2026 · Ambiente: Windows + Flutter 3.47.7 (Dart 3.13.5),
> emulador Android API 37 (Medium_Phone) e API de demonstração local.
> Escopo: revisão dos dois apps Flutter, da API de demonstração e do contrato,
> com o fluxo completo executado de ponta a ponta.

## 1. Resultado em uma linha

Os dois apps estavam **quebrados em tempo de compilação** (telas de convite
incompletas e layout do Perfil sem fechamento); depois do reparo, os dois
compilam com **0 issues** no `dart analyze`, passam **24/24** (passageiro) e
**18/18** (parceiro) testes, e os fluxos reais de corrida, **raspadinha** e
**convites** foram executados no emulador com os dois apps.

## 2. Bugs encontrados e corrigidos

| # | Bug | Impacto | Correção |
|---|---|---|---|
| 1 | `invite_screen.dart` com listas/chaves desbalanceadas e `Invite` inexistente nos dois apps | build e testes não compilavam | tela reescrita; modelo `Invite`, `myInvites()` e `generateInvite()` nos clients; rota e export registrados |
| 2 | `perfil_screen.dart` (passageiro) com spread `if (...)...[` sem fechamento e `ThemeData.surface` inexistente | build e testes não compilavam | layout reestruturado, `colorScheme.surface`, rota `/perfil-setup` registrada |
| 3 | `AppScope`/`ModalRoute` lidos em `initState` nas telas de convite e raspadinha | exceção silenciosa → tela caía em "sem conexão" | leitura movida para `didChangeDependencies` com guarda `_loaded` |
| 4 | Poll do passageiro morria na primeira falha de rede (exceção escapava do timer) | corrida aceita/finalizada ficava congelada em "Procurando" | timer encadeado com `try/catch`, sempre reagenda; `_guard` classifica falha como `offline` |
| 5 | Poll não retomava ao voltar do background | ao alternar entre apps a tela podia ficar velha | `WidgetsBindingObserver`: ao retomar, `refresh()` e religa o poll |
| 6 | Poll do parceiro fazia backoff mesmo em sucesso (até ~30 s) | oferta expira em 15 s → parceiro perdia ofertas | backoff só em erro; sucesso mantém 5 s; ciclo encadeado à prova de exceção; retomada no foreground |
| 7 | Pagamento pedia PIX mesmo quando o parceiro já havia declarado dinheiro | passageiro podia pagar duas vezes | C7 mostra "Pagamento confirmado" e vai direto para avaliação |
| 8 | Resposta do PSP ignorada (QR/copia-e-cola fixos) | tela não refletia o contrato | `RideController.pay` devolve o payload e a tela usa `pix.qr`/`pix.copia_cola` |
| 9 | `Radio.groupValue/onChanged` deprecated no Flutter 3.47 | warnings de análise | migrado para `RadioGroup` nos dois Perfis |
| 10 | Lints espalhados (`const`, chaves, imports, campos mortos) | `dart analyze` != 0 | corrigidos; **0 issues** nos dois apps |
| 11 | API de demo sem `/invites`, `/me/profile`, `/partners/nearby`, pausa e `/partner/profile` | telas novas falhavam com 404 | endpoints implementados em `scripts/demo_api.py` |
| 12 | Sem teste de regressão para pagamento confirmado e convites | regressões silenciosas | 2 novos testes de fluxo (C7 confirmado e convite) |
| 13 | Demo devolvia ticket de raspadinha esparso (`ticket_id`, sem `result`/`created_at`) e resgate com `redemption_id` | `ScratchTicket.fromJson` lançava `type 'Null' is not a subtype of type 'String' in type cast`; jogar e resgatar quebravam | API devolve o ticket completo (`id`, `campaign_id`, `user_id`, `prize_id`, `result`, `status`, `scratched_at`, `redeemed_at`, `created_at`) em play/result/histórico; resgate completo; `result` marca `SCRATCHED` e grava `scratched_at` |
| 14 | Cálculo da raspadinha dividia quantidade de pontos pela área em px² | 60% exigia ~129 mil eventos de arrasto — impossível chegar ao resultado | cobertura medida por grade de células de 8 px, com interpolação do traço e raio do pincel |
| 15 | Gesto convertia `localPosition` com `globalToLocal`; pintor não repintava (`Set` mutável) e `BlendMode.clear` sem `saveLayer` | máscara podia não revelar ou não repintar | usa `globalPosition`; revisão explícita em `shouldRepaint`; `saveLayer` ao redor da máscara |
| 16 | `ScratchCard` dentro de `Expanded` esticava a máscara por toda a tela | área raspável gigante e percentual distorcido | cartão com altura fixa de 200 dp e padding lateral |
| 17 | API de demo não implementava `PUT` (handler só tinha GET/POST) e o CORS não anunciava PUT | `PUT /me/profile` e `PUT /partner/profile` respondiam **501 HTML**, quebrando a edição de perfil | `do_PUT`, leitura de corpo para PUT e `Access-Control-Allow-Methods` com PUT |
| 18 | `openapi.yaml` tinha YAML inválido na descrição de `data_b64` e `examples` (keyword 3.1) em schema 3.0 | o contrato não passava em validador | descrição citada e `example` no lugar de `examples` |

## 3. Verificação executada

### 3.1 Estático e testes

```bash
cd app/passageiro && flutter pub get && dart analyze && flutter test   # 0 issues · 24/24
cd app/parceiro  && flutter pub get && dart analyze && flutter test   # 0 issues · 18/18
python scripts/smoke_demo_api.py                                      # 20/20 asserts
```

O smoke da API cobre: `/me` → `POST /rides` → `/offers/mine` → aceite →
`A_CAMINHO`/`CHEGOU`/`EM_VIAGEM`/`FINALIZADA` (dinheiro) → `/payments/ride`
→ `/rating` → `/partner/wallet`.

### 3.2 Fluxo real no emulador (dois apps)

Passageiro e parceiro instalados como APK debug com
`API_BASE=http://10.0.2.2:8787`, API de demo com `DEMO_AUTO_ACCEPT_S=120`
para dar tempo de alternar entre os apps.

1. Parceiro: login OTP → painel → **FICAR ONLINE** (PASSE ativo).
2. Passageiro: login OTP → "Para onde?" → "Centro, Porto Velho" (Nominatim)
   → rota por ruas (OSRM) → cotação do momento (`GET /quote`) → **Chamar**.
   O valor naquela execução foi R$ 11,04 — ele não é fixo; ver §3.7.
3. Parceiro: oferta recebida (**o mesmo valor da cotação** · coleta 1,2 km ·
   km da viagem · ≈ R$/h · cronômetro) → **ACEITAR**.
4. Parceiro: **A CAMINHO** → **CHEGUEI** → **INICIAR CORRIDA** →
   **FINALIZAR** → sheet P5 → valor da oferta → **CONFIRMEI O DINHEIRO**.
5. Passageiro: poll levou sozinho ao pagamento; como o dinheiro já estava
   confirmado, a tela mostrou **Pagamento confirmado** → **Avaliar corrida**
   → 5 estrelas → **Enviar avaliação** → home.
6. API: corrida `FINALIZADA`, `payment_status=CONFIRMED`, `fare_total`
   igual ao valor da cotação congelada no servidor (11,04 naquela
   execução); carteira do parceiro intacta (PASSE não gera comissão em
   dinheiro).

Evidências em `.preview/` (capturas do emulador): `e2e_final_*`,
`e2e_rev2_*`, `e2e_final_pass_pag_confirmado.png` e
`e2e_final_parc_oferta.png`.

### 3.3 Raspadinha e convites no emulador (fechamento desta rodada)

Raspadinha, nos dois apps (Passageiro e Parceiro), com a API de demo:

1. Perfil → **Raspadinha de prêmios** → campanha **Raspadinha da Sorte**.
2. Arrastar sobre o cartão até revelar o prêmio (`prize-002`).
3. **RESGATAR PRÊMIO** → snackbar "Prêmio resgatado com sucesso!".
4. API: ticket sai de `ISSUED` → `SCRATCHED` → `REDEEMED`, com
   `scratched_at`/`redeemed_at`; os dois apps geraram tickets e resgates.

Evidências: `e2e_final_pass_scratch_start.png`,
`e2e_final_pass_scratch_win.png`, `e2e_final_pass_scratch_redeemed.png`,
`e2e_final_parc_scratch_start.png`, `e2e_final_parc_scratch_win.png` e
`e2e_final_parc_scratch_redeemed.png`.

Convites, nos dois apps:

1. Perfil → **Convide motoristas**; estado inicial vazio no passageiro.
2. **GERAR NOVO CÓDIGO** → código `10MAIS-XXXXXX` no campo e na lista
   ("Aguardando", 12h de recompensa) + snackbar de confirmação.
3. **Copiar código** → snackbar "Código 10MAIS-XXXXXX copiado." (passageiro).
4. API: `GET /invites/mine` devolve os dois códigos `PENDING` na ordem
   mais recente primeiro.

Evidências: `e2e_final_pass_invite_empty.png`,
`e2e_final_pass_invite_generated.png`,
`e2e_final_pass_invite_copied.png`, `e2e_final_parc_invite_empty.png` e
`e2e_final_parc_invite_generated.png`.

Nota de ambiente: os APKs foram compilados com
`--dart-define=API_BASE=http://10.0.2.2:8787`. Sem esse define o default do
app é o caminho do Supabase (`/functions/v1/v1`), que a demo não serve.

### 3.4 Contrato alinhado e validado

O `openapi.yaml` passou de 26 para **39 paths / 43 operações / 22
schemas**, cobrindo perfil, convites, raspadinha, pausa e radar:

- `PUT /me/profile`, `POST /me/profile/photo`;
- `GET /invites/mine`, `POST /invites`;
- `GET /scratch/campaigns`, `POST /scratch/play`,
  `GET /scratch/tickets/{ticketId}/result`, `GET /scratch/history`,
  `POST /scratch/redeem`;
- `POST /partner/break/start`, `POST /partner/break/end`;
- `GET /partners/nearby`;
- `PUT /partner/profile`.

Schemas novos: `ProfileUpdate`, `ProfilePhotoUpdate`,
`PartnerProfileUpdate`, `PartnerInfo`, `Invite`, `InviteList`,
`ScratchCampaign`, `ScratchTicket`, `ScratchTicketList`,
`ScratchRedemption`, `NearbyDriver` e `PartnerBreak`. `Me` ganhou
`full_name`, `birth_date`, `weight`, `height`, `photo_url` e
`phone_e164`.

Validação executada:

```bash
# sintaxe, refs e regras OpenAPI 3.0
python -c "from openapi_spec_validator import validate; ..."   # VALID
# respostas reais da demo contra os schemas (jsonschema)
# 14 endpoints: /me, perfis, convites, scratch play/result/history/redeem,
# pausa e radar                                                    # 14/14
```

A validação de respostas também revelou e corrigiu o 501 de `PUT` na demo:
antes o `PUT /me/profile` e o `PUT /partner/profile` nem chegavam ao router.

### 3.5 Fluxo automatizado e reproduzível (`scripts/e2e_emulator.py`)

O roteiro manual das seções 3.2/3.3 virou um teste de um comando:

```bash
python scripts/e2e_emulator.py     # exit 0 = PASS, 1 = FAIL
```

O script é dono do ambiente inteiro, para não depender de estado deixado
por outra rodada:

1. **API isolada** — `scripts/demo_api.py` na porta 8790 (própria do teste),
   estado em memória zerado e `DEMO_AUTO_ACCEPT_S=600` para desligar o
   aceite automático: o teste quer o parceiro de verdade. Nenhum processo de
   outra porta é tocado.
2. **Emulador** — sem dispositivo adb, sobe o único AVD instalado
   (`-no-snapshot -no-boot-anim`), espera `sys.boot_completed`, fecha o
   keyguard, desliga animações e `hide_error_dialogs` (o ANR do System UI
   escondia o app do uiautomator) e encerra o AVD no fim da execução.
3. **Apps** — `flutter build apk --debug --dart-define=API_BASE=http://10.0.2.2:8790`
   nos dois projetos, `adb install -r`, `pm clear` e grant de localização:
   cada rodada começa no login, como um usuário novo.
4. **Fluxo pela UI real** — uiautomator com retry e descarte de diálogos do
   sistema: login OTP nos dois apps → parceiro **FICAR ONLINE** → passageiro
   pede (destino "Centro") → oferta no parceiro → **ACEITAR** →
   **A CAMINHO** → **CHEGUEI** → **INICIAR CORRIDA** → **FINALIZAR** →
   **CONFIRMEI O DINHEIRO** → passageiro vê "Pagamento confirmado" →
   5 estrelas → home.
5. **Asserts no servidor** (não na tela): sem corrida ativa, corrida
   `FINALIZADA`, `payment_status=CONFIRMED` (na demo só existe quando o
   parceiro declarou o dinheiro), `fare_total` numérico, parceiro real
   (não simulado) e avaliação persistida — um segundo
   `POST /rides/{id}/rating` tem de devolver `409 already_rated`.

Opções: `--no-emulator` (usa dispositivo já conectado), `--serial`,
`--skip-build` (reusa APK), `--headless`, `--gpu`, `--port`,
`--keep-emulator`, `--keep-server`, `--artifacts`, `--attempts` (3).
Cada execução grava `.preview/e2e_auto/<timestamp>-a<N>/` com 9 screenshots
do fluxo, `demo_api.log`, `emulator.log` e `result.json` (`status`,
`ride_id`, `fare_total`, `status_final`, `payment_status`, `attempts`,
`duration_s` e, em falha, `failure_kind` + `device_state`); a falha também
grava `logcat.txt`, `device.json` e `failure-ui.xml`.

### 3.6 Estabilidade: o que o teste já viu quebrar

Rodar o roteiro uma vez à mão esconde o custo real de repetir. Três classes
de falha apareceram nas primeiras execuções e cada uma virou uma regra do
harness:

| Sintoma | Causa | Regra agora |
|---|---|---|
| `timeout esperando 'Código de verificação'` / `'Avaliar a corrida'` | espera fixa de 15 s; o primeiro frame do Flutter depois do cold start passa disso | espera por condição com prazo por transição (45–60 s), e o toque é **repetido uma vez** só quando a tela de origem continua na frente (`tap_and_wait`) |
| `uiautomator dump falhou após retries` | dump espera a UI ficar idle; widget animando deixa o dump sem árvore | retentativa com `--compressed`, XML cru salvo em `failure-ui.xml` |
| `EMU_EXIT=139` no meio do fluxo | emulador 37.2.12 segfaulta de forma intermitente (Windows) | tentativa inteira refeita com AVD novo, até `--attempts` (3) |

Duas regras mantêm a retentativa honesta:

- **A retentativa não esconde bug.** Cada tentativa tem seu `result.json` com
  `failure_kind`: `infra` quando o adb perdeu o dispositivo (emulador morto) e
  `produto` quando o aparelho está vivo e a tela/contrato é que divergiu. Um
  PASS depois de falha imprime o aviso com o número da tentativa — não é um
  caminho verde limpo.
- **A falha deixa rastro.** Screenshots, logcat, `device.json`
  (fingerprint/API/ABI/tamanho da tela), `failure-ui.xml`, log da API e log
  do emulador ficam no diretório da tentativa.

Todas as esperas são por condição observável (o rótulo da próxima tela), com
prazo medido no ambiente mais lento que já rodou o teste — não `sleep` fixo.

#### Emulador deste host: instabilidade conhecida

Em 22/10/2026, depois de várias rodadas verdes, o emulador passou a **sair
sozinho** sempre no mesmo ponto: poucos segundos depois de abrir o segundo
app (o passageiro), com o parceiro já ONLINE. Sintomas: `adb` perde o
dispositivo, `emulator.log` termina sem mensagem, nenhum evento de crash no
Windows (Application Error) e nenhum relatório em `emu-crash-37.2.12.db`.
Ou seja, é o **emulador** (37.2.12 + imagem API 37), não o roteiro.

O `-show-kernel` (o script sobe o AVD com ele) mostra o guest **vivo e sadio**
até o instante da queda: a última linha é o processo do app passageiro
pedindo `IAllocator`/`mapper/ranchu` ao `servicemanager`. Ou seja, o guest
estava abrindo a pipeline gráfica quando o processo do emulador sumiu — a
falha é do lado do host, não do sistema dentro do AVD.

O que foi testado e **não** resolveu: Vulkan do guest desligado
(`-feature -Vulkan`), `-gpu swiftshader_indirect`, `-gpu guest`, headless,
build antes do boot (menos memória durante o fluxo), guest de 2 GB e um AVD
dedicado com userdata nova (`--avd e2e_passageiro`). O que o harness faz com
isso: marca a falha como `infra` (o adb perdeu o dispositivo) e repete a
tentativa com AVD novo.

Conclusão prática: neste host o teste precisa de mais de uma tentativa em
alguns momentos do dia; o ambiente de referência é o CI (emulador x86_64
limpo, API 35) — que é exatamente o motivo de o workflow existir. Resultado:
**PASS** com `FINALIZADA · CONFIRMED · R$ 11,04 · avaliada` (o valor da
cotação daquele horário; ver §3.7), por exemplo a corrida
`6d013851-d60e-48ca-800f-1470021ccdb9`, execução `20261022-161053`; a
execução `20261022-164352-a3` passou na 3ª tentativa.
O `result.json` registra quantas tentativas custou — PASS na 1ª e PASS na 3ª
não são a mesma informação.

Em CI, [`.github/workflows/e2e-emulator.yml`](../.github/workflows/e2e-emulator.yml)
(`workflow_dispatch`) builda os dois APKs, habilita acesso a `/dev/kvm`
(regra udev) e roda o script dentro do
`reactivecircus/android-emulator-runner` com `--no-emulator --skip-build
--serial "${ANDROID_SERIAL:-emulator-5554}"` — o serial vem do próprio
runner da action, então o script não sobe um segundo AVD. Emulador API 35,
x86_64, `google_apis`, `-gpu swiftshader` (o `swiftshader_indirect` está
depreciado) e `ubuntu-24.04` fixo, para o job não mudar de base sozinho;
`.preview/e2e_auto/` sobe como artefato **sempre** (`if: always()`), porque
é na falha que ele vale. `flutter test integration_test` não serve aqui: o
teste troca entre **dois apps instalados**, então é o harness
adb/uiautomator que orquestra.

Limites: é um E2E de UI no emulador, não substitui `flutter test`. Duas
falhas de ambiente foram observadas e tratadas: o ANR do System UI
(dialogo descartado + `hide_error_dialogs`) e a memória do host — com o
daemon do Gradle vivo (~900 MB) o qemu morria no meio do fluxo; o script
agora encerra o daemon depois do build. Também houve um hang de driver de
vídeo do host (`LiveKernelEvent 141`), independente do teste; por isso o
`--gpu` é configurável e o `--headless` usa `swiftshader_indirect`.

A instabilidade do emulador neste host é **intermitente**, não sistemática:
em 23/10 a mesma configuração (`--gpu swiftshader`, AVD API 37 local) deu
PASS na tentativa 1 em 6 min (`.preview/e2e_hoje/20261023-094557-a1`) e,
minutos depois, o dispositivo sumiu durante o login do parceiro
(`.preview/e2e_final_hoje/20261023-095347-a1`, `failure_kind: infra`). Não é
determinístico, então uma execução isolada não prova nem refuta — o script
repete, e o job de CI é o verde de referência.

`flutter analyze` **quebra neste caminho** (o projeto mora em `10é+`): o
servidor de análise corta a mensagem LSP no caractere acentuado do path
(`FormatException: Unexpected end of input`, exit 255). Não é lint: é o
wrapper. `dart analyze lib test` no mesmo diretório roda limpo e é a
checagem usada aqui.

### 3.7 A cotação não é um número fixo (e isso é o contrato)

A documentação acima citava "R$ 11,04" como se fosse o preço da corrida.
Numa execução às 7h50 a mesma rota (1,2 km de OSRM, Centro de Porto Velho)
foi cotada em **R$ 13,03**; de madrugada cai para **~R$ 8,03**. Nada quebrou —
`GET /quote` é tarifa dinâmica por desenho (`scripts/demo_api.py`):

```
km        = distância RODOVIÁRIA do OSRM (a mesma que o mapa desenha);
            sem rede cai em Haversine × 1,35, o mesmo fallback do app
base      = 5,00 + 2,20 × km
demanda   = 1,00 + 0,35 × peso da zona (calor dos últimos 15 min)
hora      = 1,18 no rush (7–9h, 17–19h) · 0,88 na madrugada (até 5h) · 1,00 no resto
fare_total = base × demanda × hora          (arredondado a centavos)
```

A distância da cotação é a **da rota**, não uma linha reta com piso: antes
havia um `max(1,5 km, haversine)`, o que fazia o "R$ por km" da tarifa não
fechar com o traçado na tela (mapa "1,2 km", card "1,5 km"). Agora as duas
contas partem do mesmo número, arredondado à casa que o card mostra: rota
OSRM de 1,227 km → `distance_km` 1,2 → base R$ 7,64 → ×1,33 ×1,18 = R$ 11,99.
Quem refizer a conta na tela chega no mesmo centavo. O OSRM é consultado
fora do lock e com cache de 10 min por par origem→destino: 1,8 s na
primeira cotação daquele par, ~3 ms depois (o poll de corrida/oferta dos
apps não espera rede).

O pedido congela essa mesma distância (`distance_km` na `Ride`, campo do
`openapi.yaml`) e o resto da cadeia a repete: `trip_distance_km` da oferta
que o parceiro vê e o recibo que o passageiro vê embaixo do total. Antes, a
oferta calculava Haversine × 1,35 por conta própria e o recibo não tinha
distância — era possível o card dizer 1,2 km e a oferta, 1,6 km.

O que o contrato garante, e o smoke verifica a cada execução, é a
**coerência**: o valor mostrado no card é o que o `GET /quote` congela no
servidor (desde 07/11/2026, por `quote_id` de uso único), é o que o
parceiro vê na oferta (`amount`) e é o `fare_total` final. O que ele não
garante é um número específico — por isso nenhum teste asserta R$ 11,04,
só que o valor é numérico e igual em toda a cadeia.

Desde 23/10 o card "Valor no momento" mostra a composição
(`Base R$ 7,64 · 1,2 km · demanda ×1,33 · hora ×1,18`), para o passageiro
entender por que o número mudou entre duas consultas; e se a cotação
vencer antes de **Chamar**, o app pede uma nova em vez de mandar o valor
expirado.

## 4. Achados que permanecem (não bloqueiam o MVP-A)

- O contrato já cobre os endpoints usados pelos apps, mas o `GET
  /scratch/tickets/{ticketId}/result` da demo tem efeito colateral (marca
  `SCRATCHED`). Em produção essa transição deve ser um `POST` idempotente.
- `/geocode` (proxy Nominatim da demo) continua fora do contrato: é uma
  conveniência local, não uma Edge Function de produção.
- PIX na demo desenha um QR ilustrativo e um copia-e-cola; o PSP real não
  está integrado (escopo da Fase 4).
- OTP é local (qualquer 4 dígitos), sem auth real/JWT.
- Tiles do OSM usam o servidor público (política de uso); produção exige
  provedor próprio/MapProvider.
- Os dois apps usam o mesmo usuário de demonstração; convites e
  raspadinhas são globais entre eles (não há isolamento passageiro ×
  parceiro na API em memória).
- O prêmio é revelado no payload de `POST /scratch/play` (demo); em
  produção o resultado só deve ser exposto após a raspagem mínima.
- P8 (tickets) segue no MVP-B, como documentado.
