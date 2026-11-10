// 10 é + — Edge Function "psp-webhook"
//
// A ÚNICA porta que confirma um pagamento. Ela é server-to-server: não aceita
// token de usuário, exige o segredo compartilhado do PSP e nunca "confirma por
// otimismo" — se o segredo não estiver configurado, ela recusa (503), em vez de
// aceitar qualquer coisa (era o que a demo fazia: o "webhook" era ela mesma
// confirmando sempre).
//
// Quando o PSP for contratado (ADR-005), o que muda aqui é só a validação da
// origem: assinatura HMAC/segredo do provedor no lugar de `x-psp-secret`, e a
// busca do pagamento por (psp_provider, psp_payment_id). O resto — idempotência,
// livro-razão, liberação da corrida — já é o caminho de produção.
//
// Corpo aceito (o PSP real é adaptado neste ponto):
//   { "event": "payment.confirmed", "payment_id": "<uuid>", "psp_payment_id": "..." }

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WEBHOOK_SECRET = Deno.env.get("PSP_WEBHOOK_SECRET") ?? "";

const CONFIRM_EVENTS = new Set(["payment.confirmed", "payment.paid", "charge.paid"]);

function json(status: number, payload: unknown) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

async function service(path: string, init: RequestInit = {}) {
  return await fetch(`${SUPABASE_URL}${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { code: "method_not_allowed" });

  if (!WEBHOOK_SECRET) {
    // Sem segredo não há como distinguir o PSP de um curioso: recusa explícita.
    console.error("PSP_WEBHOOK_SECRET não configurado");
    return json(503, {
      code: "webhook_not_configured",
      detail: "Defina PSP_WEBHOOK_SECRET para aceitar confirmações do PSP.",
    });
  }
  const provided = req.headers.get("x-psp-secret") ?? "";
  if (provided !== WEBHOOK_SECRET) {
    return json(401, { code: "invalid_webhook_secret" });
  }
  if (!SERVICE_KEY) return json(503, { code: "server_key_missing" });

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return json(400, { code: "invalid_json" });
  }

  const event = String(body.event ?? "");
  if (!CONFIRM_EVENTS.has(event)) {
    return json(202, { code: "ignored_event", event });
  }

  let paymentId = body.payment_id ? String(body.payment_id) : "";
  const pspPaymentId = body.psp_payment_id ? String(body.psp_payment_id) : "";

  if (!paymentId && pspPaymentId) {
    const res = await service(
      `/rest/v1/payments?select=id&psp_payment_id=eq.${encodeURIComponent(pspPaymentId)}&limit=1`,
    );
    if (res.ok) {
      const rows = await res.json();
      paymentId = rows?.[0]?.id ?? "";
    }
  }
  if (!paymentId) return json(404, { code: "payment_not_found" });

  // fn_payment_confirm_ride é idempotente (só age em PENDING) e escreve o
  // livro-razão pela partida dobrada — reentrega do PSP não duplica dinheiro.
  const res = await service("/rest/v1/rpc/fn_payment_confirm_ride", {
    method: "POST",
    body: JSON.stringify({ p_payment: paymentId, p_psp_id: pspPaymentId || "psp" }),
  });
  if (!res.ok) {
    const text = await res.text();
    console.error("fn_payment_confirm_ride falhou", res.status, text);
    // O mesmo id de PSP apontando para outra cobrança nossa é conflito real
    // (índice único `uq_payments_psp`): pede reconciliação, não repetição cega.
    if (text.includes("uq_payments_psp") || text.includes("23505")) {
      return json(409, { code: "psp_id_conflict" });
    }
    return json(500, { code: "confirm_failed" });
  }

  const check = await service(
    `/rest/v1/payments?select=id,status,ride_id,amount,confirmed_at&id=eq.${paymentId}&limit=1`,
  );
  const payment = check.ok ? (await check.json())?.[0] ?? null : null;
  return json(200, {
    code: payment?.status === "CONFIRMED" ? "confirmed" : "not_confirmed",
    payment_id: paymentId,
    payment,
  });
});
