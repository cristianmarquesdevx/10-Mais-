---
name: security-anthropic
description: Boas práticas de security para apps móveis (base em OWASP Mobile Top 10 e princípios defensivos): não hardcodear secrets, validação de entrada, comunicação segura, armazenamento protegido, validação de tokens/sessão e proteção contra injeção. Útil para auditar e endurecer o app antes de colocar em produção.
---

# security-anthropic

Checklist de security aplicável ao projeto 10 é +. Não adiciona dependências; ajusta o que já existe.

## 1. Secrets e credenciais
- Nunca hardcodear `API_TOKEN`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, JWT secrets ou chaves de API no código.
- Tokens vêm do ambiente de build (`--dart-define`) ou do fluxo de auth (OTP F1); nunca gravados em texto plano em `SharedPreferences` sem criptografia (preferir `flutter_secure_storage` quando houver dado sensível).
- `supabase/.env` não entra no repositório (confirmar no `.gitignore`).

## 2. Comunicação de rede
- Todo tráfego de API sobre HTTPS em produção; debug local (`10.0.2.2:8787`) só em dev.
- Validar certificados / não aceitar certos auto-assinados em release (certificate pinning conceitual quando houver backend próprio).
- Timeout em toda chamada de rede; nunca deixar pendente indefinido.
- Logs de rede não expõem tokens, senhas ou PII (CPF, telefone, e-mail completo).

## 3. Validação de entrada
- Todo dado do usuário validado no cliente (tamanho, formato, caracteres permitidos) E no servidor.
- Campos de telefone: máscara e validação de DDD + 9 dígitos.
- Inputs sanitizados antes de enviar para a API (evitar injeção).
- Mensagens de erro genéricas para o usuário ("Falha ao entrar") sem vazar detalhes internos do backend.

## 4. Tokens e sessão
- Token de auth enviado apenas no cabeçalho `Authorization: Bearer <token>`.
- Logout limpa token e sessão local; redireciona para login.
- Sessão expira; app trata 401/403 voltando ao login sem travar.
- Não guardar senha em nenhum lugar.

## 5. Armazenamento local
- `SharedPreferences` só para preferências não sensíveis (tema claro/escuro, modo de exibição).
- Dados de usuário, tokens ou PII nunca em `SharedPreferences` sem criptografia.
- Cache de mapa/OSM não armazena localização histórica sensível do usuário sem consentimento.

## 6. Proteção contra injeção e manipulação
- Validação de tipos em modelos Dart (`fromJson` com casts seguros; nunca `as String` sem null check).
- IDs de oferta/corrida validados antes de usar em navegação (`/offers/$id`, `/rides/$id`).
- Deep links validados antes de abrir tela interna.

## 7. Auditoria rápida
- `grep` por `API_TOKEN`, `SERVICE_ROLE`, `jwt`, `secret`, `password` no código: nenhum resultado em arquivos commiteados.
- `grep` por `print(` em telas que lidam com dados do usuário: nenhum log de PII.

## Como usar com fable-method
- Step 2 (evidência): rode os `grep` acima e leia `client.dart`, `auth_service.dart`, `theme.dart` (preferência de tema) e telas de login/pagamento.
- Step 4: corrija apenas o que falhar; nenhuma dependência nova.
- Step 5: testes existentes continuam verdes; `dart analyze` limpo.
