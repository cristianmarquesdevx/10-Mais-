# 10 é + Parceiro (MVP-A, P1–P7)

App Flutter do motorista: painel operacional, passe, carteira, oferta com
cronômetro, corrida em 3 fases, confirmação de dinheiro, cadastro/KYC,
convites e raspadinha.

## Rodar localmente

Pré-requisitos: Flutter 3.44+ e a API de demonstração do repositório.

```bash
# na raiz do repositório
python scripts/demo_api.py --port 8787

# no app (emulador Android)
flutter run --dart-define=API_BASE=http://10.0.2.2:8787
```

No Chrome/desktop, use `http://127.0.0.1:8787`. O login é OTP de
desenvolvimento (qualquer celular/4 dígitos), sem auth real.

## Fluxo P2 → P5

1. **Painel**: chip do modo (PASSE 100% seu / COMISSÃO 12%), passe, carteira
   e CTA **FICAR ONLINE**. KYC não aprovado bloqueia o online (F9).
2. Com o parceiro ONLINE, a oferta chega por poll (fallback do Realtime) e
   abre o OfferCard: bruto, coleta, corrida, destino, ≈ R$/h e cronômetro de
   15 s. **ACEITAR** é o primeiro a aceitar vence.
3. **A CAMINHO** → **CHEGUEI** → **INICIAR CORRIDA** → **FINALIZAR**.
4. P5: declarar dinheiro recebido (ou escolher pagamento digital). A
   transição para FINALIZADA envia `fare_total` e `cash_declared`.
5. Ao voltar do background, o app retoma o poll de ofertas imediatamente.

## Qualidade

```bash
flutter pub get
dart analyze        # 0 issues
flutter test        # 34 testes
flutter build web
flutter build apk --debug --dart-define=API_BASE=http://10.0.2.2:8787
```

Contrato e decisões: `docs/fase2/openapi.yaml`, `docs/PRODUTO-MESTRE.md` e
`docs/REVISAO-FASE3.md`.

## Limites desta demo

- API em memória, sem auth/ledger/PSP reais; pausa e ofertas são simuladas.
- Navegação embutida (Navigation SDK) é MVP-B; o botão “Navegar” marca o
  ponto de troca do MapProvider.
- P8 (tickets) fica para o MVP-B, como no documento mestre.
