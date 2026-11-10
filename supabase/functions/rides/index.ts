// 10 é + — Edge Function "rides"
//
// O CICLO DE CORRIDA no backend de produção. Esta função é uma fachada FINA:
// ela não decide preço, despacho, estado nem dinheiro — tudo isso vive no
// Postgres (`fn_*` / `api_*`, migração 20261027000200_rides_cycle.sql), para a
// mesma regra valer para qualquer cliente.
//
// Duas propriedades que a demo em Python não tinha:
//
//   1. IDENTIDADE DO TOKEN. A função NUNCA usa a service role no caminho do
//      app: ela repassa o `Authorization` do chamador ao PostgREST, e lá
//      `auth.uid()` (o `sub` do JWT verificado pelo GoTrue) define o ator. Um
//      passageiro não consegue pedir corrida, aceitar oferta, cancelar ou pagar
//      em nome de outro: nenhum id de usuário é aceito no corpo.
//   2. NADA AQUI CONFIRMA PAGAMENTO. `POST /rides/{id}/payment/confirm` (o "Já
//      paguei") só RELÊ o estado; a confirmação é o webhook do PSP
//      (supabase/functions/psp-webhook), que é server-to-server e assinado.
//
// Rotas (as mesmas do contrato docs/fase2/openapi.yaml):
//   GET    /me                                  (quem é o chamador)
//   GET    /quote
//   POST   /rides                     (Idempotency-Key opcional)
//   GET    /rides?active=1
//   GET    /rides/{rideId}
//   POST   /rides/{rideId}/cancel
//   GET    /rides/{rideId}/dispatch
//   GET    /offers/mine
//   GET    /offers/{offerId}
//   POST   /offers/{offerId}/accept
//   POST   /offers/{offerId}/decline
//   POST   /partner/transitions
//   POST   /payments/ride
//   GET    /payments/{paymentId}
//   POST   /rides/{rideId}/payment/confirm   ("Já paguei": só consulta)
//   POST   /rides/{rideId}/rating            (nota do outro lado da corrida)
//   POST   /rides/{rideId}/negotiation       (proposta/contraproposta, D2)
//   GET    /rides/{rideId}/negotiation       (histórico das rodadas)

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, idempotency-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(status: number, payload: unknown, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8", ...extra },
  });
}

/** Problema no formato do contrato: a tela decide por `code`, nunca por texto. */
function problem(status: number, code: string, title: string, extra: Record<string, string> = {}) {
  return json(status, { title, status, code }, extra);
}

/** Mensagem de erro do Postgres -> resposta do contrato. */
function mapError(code: string, detail: string) {
  const msg = `${code} ${detail}`;
  if (msg.includes("not_authenticated")) return problem(401, "unauthenticated", "Sessão inválida");
  if (msg.includes("active_ride_exists")) return problem(409, "active_ride_exists", "Você já tem uma corrida em andamento");
  if (msg.includes("offer_unavailable")) return problem(409, "offer_unavailable", "Oferta não está mais disponível");
  if (msg.includes("ride_not_offered")) return problem(409, "ride_not_offered", "A corrida não está mais ofertada");
  if (msg.includes("offer_not_found")) return problem(404, "not_found", "Oferta não encontrada");
  if (msg.includes("ride_already_closed")) return problem(409, "ride_already_closed", "A corrida já foi encerrada");
  if (msg.includes("ride_not_found")) return problem(404, "not_found", "Corrida não encontrada");
  if (msg.includes("payment_not_found")) return problem(404, "not_found", "Pagamento não encontrado");
  if (msg.includes("not_your_ride") || msg.includes("not_participant")) {
    return problem(403, "forbidden", "Esta corrida não é sua");
  }
  if (msg.includes("illegal_transition")) return problem(409, "illegal_transition", "Transição de fase inválida");
  if (msg.includes("already_paid")) return problem(409, "already_paid", "A corrida já está paga");
  if (msg.includes("already_rated")) return problem(409, "already_rated", "Esta corrida já foi avaliada");
  if (msg.includes("invalid_rating")) return problem(422, "invalid_rating", "Nota inválida");
  // Cotação congelada: o preço vem do servidor. `quote_id` é de uso único,
  // vale só na mesma rota e só dentro da validade.
  if (msg.includes("quote_not_found")) return problem(422, "quote_not_found", "Cotação não encontrada");
  if (msg.includes("quote_expired")) return problem(422, "quote_expired", "Cotação expirada");
  if (msg.includes("quote_mismatch")) return problem(422, "quote_mismatch", "Cotação de outra rota");
  if (msg.includes("quote_fare_mismatch")) return problem(422, "quote_fare_mismatch", "Valor divergente");
  // Negociação (D2): piso/teto/rodadas vêm dos parâmetros da cidade.
  if (msg.includes("below_floor")) return problem(422, "below_floor", "Abaixo do piso da cidade");
  if (msg.includes("above_ceiling")) return problem(422, "above_ceiling", "Acima do teto da negociação");
  if (msg.includes("rate_limited")) return problem(422, "rate_limited", "Muitas negociações agora");
  if (msg.includes("round_limit")) return problem(409, "round_limit", "As rodadas de negociação acabaram");
  if (msg.includes("above_agreed")) return problem(422, "above_agreed", "O valor passou do preço combinado");
  // Contraproposta do parceiro (D2): o valor não foi aceito pelo passageiro.
  if (msg.includes("negotiation_pending")) {
    return problem(409, "negotiation_pending", "Aguarde a resposta do passageiro à sua contraproposta");
  }
  if (msg.includes("counter_not_higher")) {
    return problem(422, "counter_not_higher", "A contraproposta precisa ser maior que o valor atual");
  }
  if (msg.includes("no_pending_counter")) {
    return problem(409, "no_pending_counter", "Não há contraproposta esperando resposta");
  }
  if (msg.includes("counter_expired")) {
    return problem(409, "counter_expired", "A contraproposta expirou");
  }
  if (msg.includes("ride_not_finished")) return problem(409, "ride_not_finished", "A corrida ainda não terminou");
  if (msg.includes("invalid_fare") || msg.includes("invalid_pricing")) {
    return problem(422, "invalid_pricing", "Valor da corrida inválido");
  }
  if (msg.includes("invalid_points") || msg.includes("invalid_method") || msg.includes("invalid_amount")) {
    return problem(422, "invalid_request", "Dados inválidos");
  }
  if (msg.includes("no_eligible_candidate") || msg.includes("no_partner_online")) {
    return problem(409, "no_partner_available", "Nenhum parceiro disponível agora");
  }
  if (msg.includes("purchase_in_flight")) return problem(409, "purchase_in_flight", "Já existe uma compra em andamento");
  if (msg.includes("kyc_not_approved") || msg.includes("not_a_partner")) {
    return problem(403, "kyc_required", "Cadastro ainda não aprovado");
  }
  return problem(500, "internal", "Falha ao processar a operação");
}

type Caller = { id: string; email?: string; token: string };

/** Confirma com o GoTrue quem é o dono do token (nada é aceito do corpo). */
async function authenticate(req: Request): Promise<Caller | null> {
  const header = req.headers.get("authorization") ?? "";
  const token = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  if (!token) return null;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${token}` },
  });
  if (!res.ok) return null;
  const user = await res.json();
  if (!user?.id) return null;
  return { id: user.id, email: user.email ?? user.phone, token };
}

/** Chama a função de domínio no Postgres COM O TOKEN DO CHAMADOR. */
async function rpc(caller: Caller, name: string, body: Record<string, unknown>) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${caller.token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  const payload = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const pgCode = String(payload?.code ?? "");
    const pgMsg = String(payload?.message ?? "");
    console.error(`rpc ${name} falhou`, pgCode, pgMsg);
    return { ok: false as const, response: mapError(pgCode, pgMsg) };
  }
  return { ok: true as const, data: payload };
}

/** Idempotência do contrato: mesma chave + mesmo corpo devolve a resposta original. */
async function idempotencyLookup(caller: Caller, key: string, endpoint: string) {
  const url = `${SUPABASE_URL}/rest/v1/idempotency_keys` +
    `?select=request_hash,response_status,response_body&key=eq.${encodeURIComponent(key)}` +
    `&endpoint=eq.${encodeURIComponent(endpoint)}&limit=1`;
  const res = await fetch(url, {
    headers: { apikey: ANON_KEY, Authorization: `Bearer ${caller.token}` },
  });
  if (!res.ok) return null;
  const rows = await res.json();
  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

async function idempotencyStore(
  caller: Caller, key: string, endpoint: string, hash: string,
  status: number, body: unknown,
) {
  // Falha aqui é registrada: sem a chave gravada, um replay cairia na regra de
  // "já existe corrida ativa" em vez de devolver a resposta original.
  const res = await fetch(`${SUPABASE_URL}/rest/v1/idempotency_keys`, {
    method: "POST",
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${caller.token}`,
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify({
      user_id: caller.id, key, endpoint, request_hash: hash,
      response_status: status, response_body: body,
    }),
  });
  if (!res.ok) {
    console.error(`idempotency_keys não gravou (${res.status})`, await res.text());
  }
}

async function hashOf(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function num(v: string | null): number | null {
  if (v === null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function point(lat: number | null, lon: number | null) {
  return lat === null || lon === null ? null : { lat, lon };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  // A URL pública chega como /functions/v1/rides/<resto>; o runtime também pode
  // entregar só o resto. Os dois casos caem no mesmo caminho relativo.
  let path = url.pathname;
  const at = path.indexOf("/rides");
  path = at >= 0 ? path.slice(at + "/rides".length) : path;
  if (!path.startsWith("/")) path = `/${path}`;
  const q = url.searchParams;

  const caller = await authenticate(req);
  if (!caller) {
    return problem(401, "unauthenticated", "Faça login para continuar");
  }

  let body: Record<string, any> = {};
  if (req.method === "POST") {
    const raw = await req.text();
    if (raw) {
      try {
        body = JSON.parse(raw);
      } catch {
        return problem(400, "invalid_json", "Corpo inválido");
      }
    }
  }

  // ---- quem é o chamador --------------------------------------------------
  //
  // A identidade vem do token (auth.uid() no Postgres), nunca do corpo: o
  // passageiro e o parceiro veem o SEU perfil, não o de um usuário fixo.
  if (req.method === "GET" && path === "/me") {
    const r = await rpc(caller, "api_me", {});
    return r.ok ? json(200, r.data) : r.response;
  }

  // ---- cotação ------------------------------------------------------------
  if (req.method === "GET" && path === "/quote") {
    const origin = point(num(q.get("origin_lat")), num(q.get("origin_lon")));
    const destination = point(num(q.get("dest_lat")), num(q.get("dest_lon")));
    if (!origin || !destination) return problem(422, "invalid_request", "Origem e destino são obrigatórios");
    const r = await rpc(caller, "api_quote", { p_origin: origin, p_destination: destination });
    return r.ok ? json(200, r.data) : r.response;
  }

  // ---- pedir corrida -----------------------------------------------------
  if (req.method === "POST" && path === "/rides") {
    const origin = body.origin ?? point(num(q.get("origin_lat")), num(q.get("origin_lon")));
    const destination = body.destination ??
      point(num(q.get("dest_lat")), num(q.get("dest_lon")));
    if (!origin || !destination) return problem(422, "invalid_request", "Origem e destino são obrigatórios");

    const idemKey = req.headers.get("idempotency-key");
    // A chave é UUID no banco (`idempotency_keys.key`): melhor recusar com um
    // erro claro do que seguir sem idempotência e devolver "corrida ativa"
    // num replay — que foi o que aconteceu antes desta checagem.
    if (idemKey && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(idemKey)) {
      return problem(422, "invalid_idempotency_key",
        "Idempotency-Key deve ser um UUID (a chave é gravada como uuid)");
    }
    const fingerprint = await hashOf(JSON.stringify(body ?? {}));
    if (idemKey) {
      const seen = await idempotencyLookup(caller, idemKey, "POST /rides");
      if (seen) {
        if (seen.request_hash !== fingerprint) {
          return problem(409, "idempotency_conflict",
            "Esta chave de idempotência foi usada com outro conteúdo");
        }
        return json(seen.response_status ?? 201, seen.response_body,
          { "Idempotency-Replayed": "true" });
      }
    }

    const r = await rpc(caller, "api_ride_request", {
      p_origin: origin,
      p_destination: destination,
      p_origin_address: body.origin_address ?? null,
      p_destination_address: body.destination_address ?? null,
      p_proposed: body.proposed_amount ?? null,
      p_client_quoted: body.quoted_fare ?? null,
      // A cotação congelada: com `quote_id`, o servidor cobra o valor gravado
      // (mesma rota, dentro da validade, uma vez). Sem ele, recalcula pela rota.
      p_quote_id: body.quote_id ?? null,
    });
    if (!r.ok) return r.response;
    if (idemKey) {
      await idempotencyStore(caller, idemKey, "POST /rides", fingerprint, 201, r.data);
    }
    return json(201, r.data);
  }

  // ---- listar / detalhar / cancelar --------------------------------------
  if (req.method === "GET" && path === "/rides") {
    const active = q.get("active") === "1" || q.get("active") === "true";
    const r = await rpc(caller, "api_rides_mine", { p_active: active });
    return r.ok ? json(200, r.data) : r.response;
  }

  const rideMatch = path.match(/^\/rides\/([0-9a-f-]{36})(\/cancel|\/dispatch|\/payment\/confirm|\/rating|\/negotiation|\/negotiation\/accept)?$/);
  if (rideMatch) {
    const rideId = rideMatch[1];
    const action = rideMatch[2] ?? "";
    if (req.method === "GET" && action === "") {
      const r = await rpc(caller, "api_ride_get", { p_ride: rideId });
      return r.ok ? json(200, r.data) : r.response;
    }
    if (req.method === "GET" && action === "/dispatch") {
      const r = await rpc(caller, "api_ride_dispatch", { p_ride: rideId });
      return r.ok ? json(200, r.data) : r.response;
    }
    if (req.method === "POST" && action === "/cancel") {
      const r = await rpc(caller, "api_ride_cancel", {
        p_ride: rideId, p_reason: body.reason ?? "PASSENGER_REGRET",
      });
      return r.ok ? json(200, r.data) : r.response;
    }
    if (req.method === "GET" && action === "/negotiation") {
      const r = await rpc(caller, "api_ride_negotiations", { p_ride: rideId });
      return r.ok ? json(200, r.data) : r.response;
    }
    if (req.method === "POST" && action === "/negotiation") {
      const amount = Number(body.amount);
      const kind = String(body.kind ?? "PROPOSE");
      if (!Number.isFinite(amount) || amount <= 0) {
        return problem(422, "invalid_request", "Valor da proposta inválido");
      }
      const r = await rpc(caller, "api_ride_negotiate", {
        p_ride: rideId,
        p_amount: amount,
        p_kind: kind,
      });
      return r.ok ? json(201, r.data) : r.response;
    }
    // O passageiro aceita o preço pedido pelo parceiro (D2).
    if (req.method === "POST" && action === "/negotiation/accept") {
      const r = await rpc(caller, "api_negotiation_accept", { p_ride: rideId });
      return r.ok ? json(200, r.data) : r.response;
    }
    if (req.method === "POST" && action === "/rating") {
      const stars = Number(body.stars);
      if (!Number.isFinite(stars)) return problem(422, "invalid_rating", "Nota inválida");
      const r = await rpc(caller, "api_ride_rate", {
        p_ride: rideId,
        p_stars: Math.trunc(stars),
        p_comment: body.comment ?? null,
        p_tags: Array.isArray(body.tags) ? body.tags : [],
      });
      return r.ok ? json(201, r.data) : r.response;
    }
    if (req.method === "POST" && action === "/payment/confirm") {
      // "Já paguei": pergunta ao SERVIDOR se o PSP confirmou. Este caminho não
      // confirma nada — quem confirma é o webhook assinado do PSP
      // (supabase/functions/psp-webhook).
      const pay = await rpc(caller, "api_payment_get_by_ride", { p_ride: rideId });
      if (!pay.ok) return pay.response;
      // A resposta é a CORRIDA (o mesmo formato de GET /rides/{id}), com o
      // estado do pagamento em cima. O app lê `payment_status` do recibo e
      // decide se avança; devolver só o pagamento quebraria o contrato que a
      // tela já consome (a demo devolvia a corrida inteira).
      const ride = await rpc(caller, "api_ride_get", { p_ride: rideId });
      if (!ride.ok) return ride.response;
      return json(200, {
        ...(ride.data as Record<string, unknown>),
        payment_id: pay.data?.payment_id ?? null,
        payment_method: pay.data?.method ?? null,
        payment_status: pay.data?.ride_payment_status ?? "NOT_DUE",
        confirmed_by: "psp_webhook",
      });
    }
  }

  // ---- despacho visto pelo app -------------------------------------------
  if (req.method === "GET" && path === "/offers/mine") {
    const r = await rpc(caller, "api_offers_mine", {});
    return r.ok ? json(200, r.data) : r.response;
  }

  const offerMatch = path.match(/^\/offers\/([0-9a-f-]{36})(\/accept|\/decline|\/counter|\/negotiation)?$/);
  if (offerMatch) {
    const offerId = offerMatch[1];
    const action = offerMatch[2] ?? "";
    if (req.method === "GET" && action === "") {
      const r = await rpc(caller, "api_offer_get", { p_offer: offerId });
      return r.ok ? json(200, r.data) : r.response;
    }
    if (req.method === "POST" && action === "/accept") {
      // Anti-colusão (SPECS §3): par com corridas negociadas demais na janela
      // não segue negociando. O bloqueio é recusado AQUI e não dentro da
      // função de aceite porque um RAISE desfaria o flag de auditoria gravado
      // na mesma transação — a tentativa precisa ficar registrada.
      const pair = await rpc(caller, "api_pair_negotiation_status", { p_offer: offerId });
      if (pair.ok && pair.data?.blocked === true) {
        await rpc(caller, "api_flag_pair_block", { p_offer: offerId });
        return problem(409, "pair_negotiation_blocked",
          "Negociação bloqueada entre vocês por ora");
      }
      const r = await rpc(caller, "api_offer_accept", { p_offer: offerId });
      return r.ok ? json(200, r.data) : r.response;
    }      if (req.method === "POST" && action === "/decline") {
        const r = await rpc(caller, "api_offer_decline", { p_offer: offerId });
        return r.ok ? json(200, r.data) : r.response;
      }
      // Contraproposta do parceiro: piso/teto e o teto de rodadas são do
      // servidor; aqui só se repassa o valor pedido.
      if (req.method === "POST" && action === "/counter") {
        if (typeof body.amount !== "number" || body.amount <= 0) {
          return problem(422, "invalid_request", "amount é obrigatório");
        }
        const r = await rpc(caller, "api_offer_counter", { p_offer: offerId, p_amount: body.amount });
        return r.ok ? json(200, r.data) : r.response;
      }
      if (req.method === "GET" && action === "/negotiation") {
        const r = await rpc(caller, "api_offer_negotiation", { p_offer: offerId });
        return r.ok ? json(200, r.data) : r.response;
      }
  }

  // ---- fases da corrida (parceiro) ---------------------------------------
  if (req.method === "POST" && path === "/partner/transitions") {
    if (!body.ride_id || !body.to) return problem(422, "invalid_request", "ride_id e to são obrigatórios");
    const r = await rpc(caller, "api_ride_transition", {
      p_ride: body.ride_id,
      p_to: body.to,
      p_fare: body.fare_total ?? null,
      p_cash_declared: body.cash_declared === true,
    });
    return r.ok ? json(200, r.data) : r.response;
  }

  // ---- pagamento ---------------------------------------------------------
  if (req.method === "POST" && path === "/payments/ride") {
    if (!body.ride_id) return problem(422, "invalid_request", "ride_id é obrigatório");
    const r = await rpc(caller, "api_payment_intent", {
      p_ride: body.ride_id,
      p_method: body.method ?? "PIX",
    });
    if (!r.ok) return r.response;
    const intent = r.data ?? {};
    // O QR e o copia-e-cola são do PSP. Enquanto não houver PSP contratado
    // (ADR-005), a resposta traz `pix: null` e o motivo — em vez de um QR falso
    // que faria a tela parecer paga.
    const provider = String(intent.psp_provider ?? "");
    const realPsp = provider !== "" && provider !== "dev_pix";
    return json(201, {
      ...intent,
      pix: null,
      checkout: realPsp
        ? { provider, ready: true }
        : {
          provider: provider || "dev_pix",
          ready: false,
          reason: "psp_not_integrated",
          note: "Nenhum PSP contratado: o PIX é criado pendente e só o webhook " +
            "assinado do PSP confirma (supabase/functions/psp-webhook).",
        },
    });
  }

  const payMatch = path.match(/^\/payments\/([0-9a-f-]{36})$/);
  if (req.method === "GET" && payMatch) {
    const r = await rpc(caller, "api_payment_get", { p_payment: payMatch[1] });
    return r.ok ? json(200, r.data) : r.response;
  }

  return problem(404, "not_found", `Rota não implementada: ${req.method} ${path}`);
});
