-- =============================================================================
-- 10 é + — quem é o chamador (GET /me)
--
-- A tela de perfil dos dois apps abre com `GET /me`. Na demonstração esse
-- endpoint devolvia um usuário fixo ("demo-user"), que não tem nada a ver com
-- a conta que autenticou — o app mostrava o perfil de um lado e falava com o
-- banco do outro.
--
-- Aqui a identidade vem do TOKEN: `auth.uid()` (o `sub` do JWT verificado
-- pelo GoTrue) é o ator, e nenhum id de usuário é aceito do corpo. A função
-- devolve o que o app mostra:
--
--   passageiro: user_id, role, phone_e164, email, full_name, photo_url,
--                birth_date
--   parceiro:   o mesmo + `partner {kyc_status, monetization_mode,
--                pass_expires_at, wallet_balance, debt_cents}`
--
-- O saldo da carteira é o livro-razão: soma dos lançamentos na conta WALLET
-- do parceiro (entradas menos saídas). Quando o saldo é negativo, o parceiro
-- deve dinheiro à plataforma — é a dívida em centavos que o app usa para
-- bloquear só o dinheiro (ADR-003), nunca a corrida.
--
-- O passe vigente é o que ainda vale (ACTIVE/QUEUED/SCHEDULED): o relógio é
-- o do servidor, nunca o do aparelho.
-- =============================================================================

CREATE OR REPLACE FUNCTION api_me()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid     uuid := app_uid();
  v_user    users%ROWTYPE;
  v_profile profiles%ROWTYPE;
  v_partner partners%ROWTYPE;
  v_balance numeric := 0;
  v_pass_expires timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_user FROM users WHERE id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE user_id = v_uid;

  SELECT * INTO v_partner
    FROM partners
   WHERE user_id = v_uid AND deleted_at IS NULL;

  -- O bloco `partner` só existe para quem É parceiro. O seed de
  -- desenvolvimento deixou uma linha em `partners` também para o passageiro
  -- (para o console antigo ter o que mostrar) — sem este gate o passageiro
  -- receberia KYC e carteira que não são seus.
  IF v_partner.user_id IS NOT NULL AND v_user.role = 'PARTNER' THEN
    -- Saldo = entradas − saídas na conta WALLET do parceiro.
    SELECT COALESCE(SUM(CASE WHEN e.direction = 'C' THEN e.amount
                              ELSE -e.amount END), 0)
      INTO v_balance
      FROM ledger_entries e
      JOIN ledger_accounts a ON a.id = e.account_id
     WHERE a.owner_type = 'PARTNER'
       AND a.owner_user_id = v_uid
       AND a.kind = 'WALLET';

    -- Passe vigente: o mais longe no tempo entre os que ainda valem.
    SELECT max(p.expires_at)
      INTO v_pass_expires
      FROM partner_passes p
     WHERE p.partner_user_id = v_uid
       AND p.status IN ('ACTIVE', 'QUEUED', 'SCHEDULED');
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'user_id',    v_user.id,
    'role',       v_user.role,
    'phone_e164', v_user.phone_e164,
    'email',      v_user.email,
    'full_name',  v_profile.full_name,
    'photo_url',  v_profile.photo_url,
    'birth_date', v_profile.birth_date,
    'partner', CASE WHEN v_partner.user_id IS NULL OR v_user.role <> 'PARTNER'
                    THEN NULL ELSE jsonb_build_object(
        'kyc_status',        v_partner.kyc_status,
        'monetization_mode', v_partner.monetization_mode,
        'pass_expires_at',   v_pass_expires,
        'wallet_balance',    v_balance,
        'debt_cents',        GREATEST(0, CEIL(-v_balance * 100))::int
      ) END
  ));
END $$;

-- Só o próprio usuário autenticado chama esta função.
REVOKE ALL ON FUNCTION api_me() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_me() TO authenticated, service_role;
