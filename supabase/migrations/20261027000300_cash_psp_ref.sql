-- -----------------------------------------------------------------------------
-- Dinheiro declarado: referência do PSP única por cobrança.
--
-- `payments` tem índice único em (psp_provider, psp_payment_id). A declaração de
-- dinheiro confirmava com o literal 'CASH_DECLARED' em TODAS as corridas, então
-- a SEGUNDA corrida paga em espécie estourava
--   duplicate key value violates unique constraint "uq_payments_psp"
-- e a transição FINALIZADA era desfeita (o app do parceiro ficava preso em
-- viagem; o passageiro, em "Em viagem"). A referência passa a ser derivada da
-- própria cobrança: única entre corridas e ESTÁVEL na reentrega, que é o que
-- mantém a idempotência do `fn_payment_confirm_ride`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_ride_cash_declare(p_ride uuid, p_amount numeric)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); r rides%ROWTYPE; v_pay uuid; v_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF r.partner_user_id IS DISTINCT FROM v_uid AND NOT app_is_agent() THEN
    RAISE EXCEPTION 'not_your_ride' USING ERRCODE = '42501';
  END IF;
  IF r.status <> 'FINALIZADA' THEN
    RAISE EXCEPTION 'ride_not_finished' USING ERRCODE = '40900';
  END IF;
  SELECT id, status INTO v_pay, v_status
    FROM payments WHERE ride_id = p_ride AND method = 'CASH' LIMIT 1;
  IF v_pay IS NULL THEN
    INSERT INTO payments (ride_id, payer_user_id, method, amount, status,
                          psp_provider, idempotency_key)
    VALUES (p_ride, r.passenger_user_id, 'CASH', COALESCE(p_amount, r.fare_total),
            'PENDING', 'cash', 'cash:' || p_ride)
    RETURNING id INTO v_pay;
    v_status := 'PENDING';
  END IF;
  -- Confirma pelo MESMO caminho do PSP (idempotente: reentrega não duplica).
  IF v_status <> 'CONFIRMED' THEN
    PERFORM fn_payment_confirm_ride(v_pay, 'cash_declared:' || v_pay::text);
  END IF;
  RETURN v_pay;
END $$;
