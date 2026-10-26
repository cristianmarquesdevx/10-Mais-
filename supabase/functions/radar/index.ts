// 10 é + — Edge Function "radar"
//
// Substitui os motoristas sintéticos do endpoint /partners/nearby da demo por
// presença REAL do app do parceiro (partner_presence) e devolve, para o
// passageiro, apenas posições aproximadas e um id pseudônimo diário.
//
// Rotas (todas exigem JWT — o gateway do Supabase valida antes daqui):
//   POST /radar/presence  { status: "ONLINE_DISPONIVEL"|"PAUSA"|"OFFLINE",
//                           lat?, lon? }
//   GET  /radar/nearby?lat=..&lon=..&radius_km=..
//
// As regras de negócio (KYC, heartbeat, raio, privacidade) vivem no Postgres
// (fn_presence_update / fn_nearby_partners), não nesta função — assim a mesma
// regra vale para qualquer cliente.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

function json(status: number, payload: unknown): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

function problem(status: number, code: string, title: string): Response {
  return json(status, { title, status, code });
}

type RpcResult = { ok: boolean; status: number; data: unknown };

async function rpc(
  name: string,
  body: Record<string, unknown>,
  authorization: string,
): Promise<RpcResult> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: ANON_KEY,
      Authorization: authorization,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let data: unknown = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { message: text };
  }
  return { ok: res.ok, status: res.status, data };
}

/** O Postgres fala pelos códigos de negócio; a borda só traduz para HTTP. */
function mapDbError(data: unknown): Response {
  const message =
    typeof data === "object" && data !== null
      ? String((data as Record<string, unknown>).message ?? "")
      : String(data ?? "");
  if (message.includes("not_authenticated")) {
    return problem(401, "not_authenticated", "Sessão inválida");
  }
  if (message.includes("not_a_partner")) {
    return problem(403, "not_a_partner", "Conta sem perfil de parceiro");
  }
  if (message.includes("kyc_not_approved")) {
    return problem(403, "kyc_not_approved", "KYC pendente");
  }
  if (message.includes("invalid_position")) {
    return problem(422, "invalid_position", "Posição inválida");
  }
  if (message.includes("invalid_status")) {
    return problem(422, "invalid_status", "Status inválido");
  }
  return problem(500, "radar_error", "Falha ao consultar presença");
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization) {
    return problem(401, "not_authenticated", "Faça login para continuar");
  }

  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/radar/, "") || "/";

  if (req.method === "GET" && path === "/nearby") {
    const lat = Number(url.searchParams.get("lat"));
    const lon = Number(url.searchParams.get("lon"));
    const radius = Number(url.searchParams.get("radius_km") ?? "5");
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      return problem(422, "invalid_position", "lat/lon obrigatórios");
    }
    const r = await rpc(
      "fn_nearby_partners",
      {
        p_lat: lat,
        p_lon: lon,
        p_radius_km: Number.isFinite(radius) ? radius : 5,
        p_limit: 30,
      },
      authorization,
    );
    if (!r.ok) return mapDbError(r.data);

    const rows = Array.isArray(r.data) ? r.data : [];
    const drivers = rows.map((row) => {
      const d = row as Record<string, unknown>;
      return {
        driver_id: d.driver_id,
        lat: d.lat,
        lon: d.lon,
        distance_km: d.distance_km,
        vehicle: d.vehicle ?? null,
        available: true,
      };
    });
    const eligible = rows.length
      ? Number((rows[0] as Record<string, unknown>).eligible_total ?? rows.length)
      : 0;
    return json(200, {
      drivers,
      eligible_count: eligible,
      radius_km: Number.isFinite(radius) ? radius : 5,
      generated_at: new Date().toISOString(),
    });
  }

  if (req.method === "POST" && path === "/presence") {
    let body: Record<string, unknown> = {};
    try {
      body = await req.json();
    } catch {
      return problem(400, "bad_request", "JSON inválido");
    }
    const status = String(body.status ?? "");
    const lat = body.lat == null ? null : Number(body.lat);
    const lon = body.lon == null ? null : Number(body.lon);
    const r = await rpc(
      "fn_presence_update",
      { p_status: status, p_lat: lat, p_lon: lon },
      authorization,
    );
    if (!r.ok) return mapDbError(r.data);
    return json(200, r.data ?? {});
  }

  return problem(404, "not_found", `Rota não encontrada: ${req.method} ${path}`);
});
