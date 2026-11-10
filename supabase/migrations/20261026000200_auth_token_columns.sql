-- =============================================================================
-- 10 é + — tokens do auth.users não podem ser NULL
--
-- As contas de desenvolvimento semeadas pela migration anterior entraram com as
-- colunas de token NULL (o INSERT não as citava e elas são nullable). O GoTrue
-- 2.197 não lê isso: `POST /auth/v1/otp` para essas contas respondia
--   500  error finding user: sql: Scan error on column index 3,
--        name "confirmation_token": converting NULL to string is unsupported
--
-- Contas criadas pelo próprio GoTrue nascem com '' nessas colunas; aqui o mesmo
-- estado é garantido para qualquer linha inserida por SQL (seed, importação,
-- migração de dados). O bloco é dinâmico porque os nomes variam entre versões.
-- =============================================================================
DO $$
DECLARE
  col text;
BEGIN
  FOREACH col IN ARRAY ARRAY[
    'confirmation_token',
    'recovery_token',
    'email_change_token_new',
    'email_change',
    'email_change_token_current',
    'phone_change',
    'phone_change_token',
    'reauthentication_token'
  ] LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = col
    ) THEN
      EXECUTE format('UPDATE auth.users SET %I = %L WHERE %I IS NULL', col, '', col);
    END IF;
  END LOOP;
END $$;
