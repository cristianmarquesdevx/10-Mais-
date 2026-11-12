-- =============================================================================
-- 10 é + — o console da operação: quem está logado
--
-- O console (app/console) é a superfície IRMÃ do passageiro e do parceiro
-- (docs/PRODUTO-MESTRE.md, Fase 3): é onde a pessoa da operação lê a fila do
-- KYC, vê o prazo e decide.
--
-- A tela do console recusa, no cliente, a conta que não é da operação. Mas a
-- RECUSA que vale é a do servidor: é o `users.role` do banco que decide, e
-- ele é escrito pelo trigger de identidade — nunca pelo corpo de um pedido.
-- Esta função dá ao console essa verdade (quem eu sou, sou da operação?),
-- sem depender do `/me` do ciclo de corrida (que é de outra função e trata
-- de passageiro/parceiro).
--
-- O que a função devolve:
--   user_id   o id da conta (vem do token)
--   email     o e-mail da conta (o canal do piloto)
--   role      PASSENGER | PARTNER | AGENT | ADMIN
--   is_agent  true para AGENT/ADMIN — o que abre a fila do KYC
-- =============================================================================

CREATE OR REPLACE FUNCTION api_kyc_me()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid   uuid := app_uid();
  v_email text;
  v_role  text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT u.email, u.role INTO v_email, v_role
    FROM users u
   WHERE u.id = v_uid;

  -- A conta existe no GoTrue mas não no produto (o trigger de identidade
  -- ainda não rodou): o console recusa, e a mensagem é clara.
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'user_id',  v_uid,
    'email',    v_email,
    'role',     v_role,
    'is_agent', app_is_agent()));
END $$;

-- Só a própria conta autenticada chama esta função.
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'api_kyc_me'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;
