// 10 é + — Edge Function "kyc"
//
// O KYC (cadastro do parceiro) no backend de produção. Esta função é uma
// FACHADA FINA, no mesmo padrão da `rides`: ela NÃO decide, não aprova, não
// enfileira — tudo isso vive no Postgres (`api_kyc_*`, migração
// 20261110000500_kyc_api.sql), para a mesma regra valer para qualquer
// cliente.
//
// A propriedade que a demonstração em Python não tinha:
//
//   IDENTIDADE DO TOKEN. A função NUNCA usa a service role no caminho do
//   app: ela repassa o `Authorization` do chamador ao PostgREST, e lá
//   `auth.uid()` (o `sub` do JWT verificado pelo GoTrue) define o ator. Um
//   parceiro não abre caso no nome de outro, e um passageiro não entra na
//   fila da operação.
//
// Rotas (as mesmas do contrato docs/fase2/openapi.yaml, servidas pela
// função `kyc` — o prefixo `/kyc` do contrato é o nome da função, então a
// rota interna é `/cases`):
//   POST /cases                              (abre/retoma o caso; Idempotency-Key)
//   GET  /cases/{caseId}                     (o caso do chamador)
//   POST /cases/{caseId}/documents           (reenvio da documentação)
//   GET  /queue                              (fila da operação — só agente)
//   POST /cases/{caseId}/review              (decisão — só agente)

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
  if (msg.includes("not_authenticated")) {
    return problem(401, "unauthenticated", "Faça login para continuar");
  }
  if (msg.includes("not_a_partner")) {
    return problem(403, "not_a_partner", "Cadastro de parceiro não encontrado");
  }
  if (msg.includes("forbidden")) {
    return problem(403, "forbidden", "Você não pode ver este caso");
  }
  if (msg.includes("kyc_case_not_found")) {
    return problem(404, "not_found", "Caso não encontrado");
  }
  if (msg.includes("kyc_already_approved")) {
    return problem(409, "kyc_already_approved", "Este cadastro já está aprovado");
  }
  if (msg.includes("kyc_case_not_in_queue")) {
    return problem(409, "kyc_case_not_in_queue", "Este caso já foi decidido");
  }
  if (msg.includes("rejection_code_required")) {
    return problem(422, "rejection_code_required", "Informe o motivo da recusa");
  }
  if (msg.includes("invalid_doc_type")) {
    return problem(422, "invalid_request", "Tipo de documento inválido");
  }
  if (msg.includes("invalid_decision")) {
    return problem(422, "invalid_request", "Decisão inválida");
  }
  return problem(500, "internal", "Falha ao processar a operação");
}

type Caller = { id: string; token: string };

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
  return { id: user.id, token };
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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  // A URL pública chega como /functions/v1/kyc/<resto>; o runtime entrega o
  // caminho já sem o prefixo do gateway (/kyc/<resto>). A rota interna é a
  // do contrato SEM o nome da função (`/cases`), então os prefixos
  // `/functions/v1` e `/kyc` (repetido, se vier) são removidos.
  let path = url.pathname.replace(/^\/functions\/v1/, "");
  path = path.replace(/^(?:\/kyc)+(?=\/|$)/, "");
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

  // ---- abrir (ou retomar) o caso ------------------------------------------
  if (req.method === "POST" && path === "/cases") {
    const idemKey = req.headers.get("idempotency-key");
    // A chave é UUID no banco (`idempotency_keys.key`): melhor recusar com um
    // erro claro do que seguir sem idempotência.
    if (idemKey && !UUID.test(idemKey)) {
      return problem(422, "invalid_idempotency_key",
        "Idempotency-Key deve ser um UUID (a chave é gravada como uuid)");
    }
    const fingerprint = await hashOf(JSON.stringify(body ?? {}));
    if (idemKey) {
      const seen = await idempotencyLookup(caller, idemKey, "POST /kyc/cases");
      if (seen) {
        if (seen.request_hash !== fingerprint) {
          return problem(409, "idempotency_conflict",
            "Esta chave de idempotência foi usada com outro conteúdo");
        }
        return json(seen.response_status ?? 201, seen.response_body,
          { "Idempotency-Replayed": "true" });
      }
    }

    const r = await rpc(caller, "api_kyc_case_create", {});
    if (!r.ok) return r.response;
    if (idemKey) {
      await idempotencyStore(caller, idemKey, "POST /kyc/cases", fingerprint, 201, r.data);
    }
    return json(201, r.data);
  }

  // ---- fila da operação (só agente) ---------------------------------------
  if (req.method === "GET" && path === "/queue") {
    const limit = Number(q.get("limit") ?? 50);
    const r = await rpc(caller, "api_kyc_queue", {
      p_limit: Number.isFinite(limit) ? Math.trunc(limit) : 50,
    });
    return r.ok ? json(200, r.data) : r.response;
  }

  // ---- caso do chamador / documento / decisão ------------------------------
  const caseMatch = path.match(/^\/cases\/([0-9a-f-]{36})(\/documents|\/review)?$/);
  if (caseMatch) {
    const caseId = caseMatch[1];
    const action = caseMatch[2] ?? "";

    if (req.method === "GET" && action === "") {
      const r = await rpc(caller, "api_kyc_case_get", { p_case: caseId });
      return r.ok ? json(200, r.data) : r.response;
    }

    if (req.method === "POST" && action === "/documents") {
      const r = await rpc(caller, "api_kyc_case_document", {
        p_case: caseId,
        p_doc_type: body.doc_type ?? body.document_type ?? null,
        p_storage_path: body.storage_path ?? null,
        p_expires_at: body.expires_at ?? null,
        p_quality_flags: body.quality_flags ?? {},
      });
      return r.ok ? json(201, r.data) : r.response;
    }

    if (req.method === "POST" && action === "/review") {
      const r = await rpc(caller, "api_kyc_review", {
        p_case: caseId,
        p_decision: body.decision ?? body.status ?? null,
        p_rejection_code: body.rejection_code ?? null,
        p_note: body.note ?? null,
      });
      return r.ok ? json(200, r.data) : r.response;
    }
  }

  return problem(404, "not_found", "Rota não encontrada");
});
