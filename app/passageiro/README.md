# 10 é + Passageiro (MVP-A)

App Flutter do cliente: mapa, cotação do momento, negociação, acompanhamento
da corrida, pagamento (PIX/cartão/dinheiro), avaliação, histórico, perfil,
convites e raspadinha de prêmios.

## Rodar localmente

Pré-requisitos: Flutter 3.44+ e a API de demonstração do repositório.

```bash
# na raiz do repositório
python scripts/demo_api.py --port 8787

# no app (emulador Android: 10.0.2.2 aponta para o host)
flutter run --dart-define=API_BASE=http://10.0.2.2:8787
```

No Chrome/desktop, use `http://127.0.0.1:8787`. Em release a URL vem do
ambiente de build (`API_BASE`); nunca fica hardcoded no código.

O login é o fluxo OTP de desenvolvimento: qualquer celular com DDD e qualquer
código de 4 dígitos entram. A demo não tem auth real.

## Fluxo C1 → C8

1. **Para onde?** → buscar endereço (geocoding) → escolher sugestão.
2. A tela mostra rota por ruas (OSRM) e o **valor do momento** (`/quote`),
   com validade e re-cotação automática.
3. **Chamar** cria a corrida (tarifa ou proposta negociada).
4. A fila faz poll de fallback e o radar mostra parceiros próximos.
5. O parceiro aceita → acompanhar → em viagem → pagamento → avaliação.
6. Se o parceiro já declarou dinheiro, o pagamento aparece como confirmado
   e vai direto para a avaliação.

## Qualidade

```bash
flutter pub get
dart analyze        # 0 issues
flutter test        # 24 testes
flutter build web   # build de produção web
flutter build apk --debug --dart-define=API_BASE=http://10.0.2.2:8787
```

Contrato e decisões: `docs/fase2/openapi.yaml`, `docs/PRODUTO-MESTRE.md` e
`docs/REVISAO-FASE3.md`.

## Limites desta demo

- API em memória (`scripts/demo_api.py`), sem auth, ledger ou PSP reais.
- PIX é ilustrativo; o checkout hospedado entra na fase de pagamentos.
- Tiles do OpenStreetMap público: produção exige provedor próprio.
