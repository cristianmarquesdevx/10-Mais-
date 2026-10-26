-- =============================================================================
-- 10 e + (dezemais) — Initial schema (PostgreSQL 16 + PostGIS 3.x)
-- Migration candidate: 0001_schema.sql (Fase 2, ADR-002..008)
-- Decisions:
--   * UUID PKs (gen_random_uuid), timestamptz UTC everywhere; city tz is data.
--   * States: text + CHECK (cheap MVP evolution) instead of PG enums.
--   * Money: numeric(12,2) BRL; ledger amounts always positive + direction.
--   * Append-only: ledger_entries, ride_events, audit_log (trigger-guarded).
--   * Partitioning: locations (daily, retention 7d), ride_events & ledger_entries
--     (monthly). Unique idempotency keys are per-partition (documented trade-off).
--   * T7: city_configs are versioned rows with validity windows, never hardcoded.
-- Retention policy (LGPD): locations 7d (drop partition); ride_events 5y
--   [VERIFICAR jurídico — fiscal pode exigir]; delivery_photos 30d (PRM-foto.retencao);
--   notifications 90d; kyc docs: while partner active + 5y after exit [VERIFICAR].
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- -----------------------------------------------------------------------------
-- Identity, city, config
-- -----------------------------------------------------------------------------
CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),  -- = auth.users.id
  phone_e164    text NOT NULL UNIQUE CHECK (phone_e164 ~ '^\+[1-9]\d{6,14}$'),
  role          text NOT NULL CHECK (role IN ('PASSENGER','PARTNER','AGENT','ADMIN','AUDITOR')),
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','DELETED')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz                                   -- soft delete
);

CREATE TABLE profiles (
  user_id       uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  full_name     text NOT NULL,
  photo_url     text,
  birth_date    date,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE device_sessions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id     text NOT NULL,               -- app-generated stable id
  platform      text NOT NULL CHECK (platform IN ('ANDROID','IOS','WEB')),
  is_emulator   boolean NOT NULL DEFAULT false,
  is_rooted     boolean NOT NULL DEFAULT false,
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
-- REQ-002/A7: one active partner session at a time (two-device fraud)
CREATE UNIQUE INDEX one_active_partner_session
  ON device_sessions (user_id) WHERE revoked_at IS NULL;
CREATE INDEX idx_device_sessions_user ON device_sessions (user_id, last_seen_at DESC);

CREATE TABLE cities (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  uf            char(2) NOT NULL,
  status        text NOT NULL DEFAULT 'PILOT' CHECK (status IN ('PILOT','ACTIVE','PAUSED')),
  timezone      text NOT NULL DEFAULT 'America/Porto_Velho',
  boundary      geography(Polygon, 4326),     -- geofence de operação
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE service_types (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code          text NOT NULL UNIQUE CHECK (code IN ('RIDE_CAR','DELIVERY_MOTO')),
  display_name  text NOT NULL,
  active        boolean NOT NULL DEFAULT true
);

-- T7: versioned, per-city parameters with validity windows. Never hardcoded.
CREATE TABLE city_configs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_id       uuid NOT NULL REFERENCES cities(id),
  param_key     text NOT NULL,                -- ex.: 'PRM-passe.preco', 'PRM-comissao.pct'
  param_value   jsonb NOT NULL,
  valid_from    timestamptz NOT NULL,
  valid_to      timestamptz,                  -- NULL = open-ended
  created_by    uuid REFERENCES users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE UNIQUE INDEX uq_city_config_window
  ON city_configs (city_id, param_key, valid_from);
CREATE VIEW city_config_current AS
  SELECT DISTINCT ON (city_id, param_key) city_id, param_key, param_value, valid_from
  FROM city_configs
  WHERE now() >= valid_from AND (valid_to IS NULL OR now() < valid_to)
  ORDER BY city_id, param_key, valid_from DESC;

CREATE TABLE feature_flags (
  key             text PRIMARY KEY,
  enabled         boolean NOT NULL DEFAULT false,
  rollout_percent integer NOT NULL DEFAULT 0 CHECK (rollout_percent BETWEEN 0 AND 100),
  constraints     jsonb NOT NULL DEFAULT '{}'::jsonb,   -- ex.: {"city_id": "..."}
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid REFERENCES users(id)
);

-- -----------------------------------------------------------------------------
-- Partner domain
-- -----------------------------------------------------------------------------
CREATE TABLE partners (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  city_id         uuid NOT NULL REFERENCES cities(id),
  kyc_status      text NOT NULL DEFAULT 'NOT_STARTED'
                  CHECK (kyc_status IN ('NOT_STARTED','IN_REVIEW','APPROVED','REJECTED','RESUBMIT')),
  -- ORTOGONAL attribute (never blocks offers): monetization mode
  monetization_mode text NOT NULL DEFAULT 'COMISSAO'
                  CHECK (monetization_mode IN ('PASSE_ATIVO','COMISSAO')),
  rating_avg      numeric(3,2) NOT NULL DEFAULT 5.00 CHECK (rating_avg BETWEEN 1 AND 5),
  rating_count    integer NOT NULL DEFAULT 0,
  acceptance_rate numeric(5,4) NOT NULL DEFAULT 1.0000,
  cancel_fault_7d integer NOT NULL DEFAULT 0,
  online_seconds_total bigint NOT NULL DEFAULT 0,
  suspect_score   numeric(4,3) NOT NULL DEFAULT 0.000,  -- antifraude: revisão, nunca despacho
  created_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);
CREATE INDEX idx_partners_dispatch
  ON partners (city_id) WHERE kyc_status = 'APPROVED' AND deleted_at IS NULL;

-- Online presence + last position (dispatch reads this; history lives in locations)
CREATE TABLE partner_presence (
  partner_user_id uuid PRIMARY KEY REFERENCES partners(user_id) ON DELETE CASCADE,
  online_status   text NOT NULL DEFAULT 'OFFLINE'
                  CHECK (online_status IN ('OFFLINE','ONLINE_DISPONIVEL','OFERTA_PENDENTE','EM_CORRIDA','EM_ENTREGA','PAUSA')),
  pause_reason    text,
  last_position   geography(Point, 4326),
  last_position_at timestamptz,
  stale_after     timestamptz,               -- RT/A2: UI mostra "localização atrasada"
  last_heartbeat_at timestamptz,
  session_id      uuid REFERENCES device_sessions(id),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_presence_gist ON partner_presence USING GIST (last_position)
  WHERE online_status IN ('ONLINE_DISPONIVEL','OFERTA_PENDENTE','EM_CORRIDA','EM_ENTREGA');

CREATE TABLE vehicles (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_user_id   uuid NOT NULL REFERENCES partners(user_id) ON DELETE CASCADE,
  plate             text NOT NULL UNIQUE,
  brand             text NOT NULL,
  model             text NOT NULL,
  color             text NOT NULL,
  category          text NOT NULL DEFAULT 'CAR',
  service_type_id   uuid NOT NULL REFERENCES service_types(id),
  active            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- KYC (REQ-005)
-- -----------------------------------------------------------------------------
CREATE TABLE kyc_cases (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_user_id   uuid NOT NULL REFERENCES partners(user_id) ON DELETE CASCADE,
  status            text NOT NULL DEFAULT 'IN_REVIEW'
                    CHECK (status IN ('AUTO_APPROVED','IN_REVIEW','REJECTED','RESUBMIT')),
  score             numeric(5,2),            -- combinado: OCR + face + qualidade
  rejection_code    text,                    -- motivo padronizado
  assigned_agent_id uuid REFERENCES users(id),
  sla_due_at        timestamptz,
  decided_at        timestamptz,
  decided_by        uuid REFERENCES users(id),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_kyc_queue ON kyc_cases (sla_due_at) WHERE status IN ('IN_REVIEW','RESUBMIT');

CREATE TABLE kyc_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id       uuid NOT NULL REFERENCES kyc_cases(id) ON DELETE CASCADE,
  doc_type      text NOT NULL CHECK (doc_type IN ('CNH','CRLV','SELFIE','PROOF_ADDRESS','OTHER')),
  storage_path  text NOT NULL,               -- Storage privado; URLs assinadas curtas
  ocr_data      jsonb,                       -- PII sensível: criptografia em repouso [SEC]
  quality_flags jsonb NOT NULL DEFAULT '{}'::jsonb,  -- blur/glare/cut detectados
  expires_at    date,                        -- validade do documento
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Core marketplace: rides (+ deliveries extension), offers, negotiations
-- -----------------------------------------------------------------------------
CREATE TABLE rides (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  city_id               uuid NOT NULL REFERENCES cities(id),
  service_type_id       uuid NOT NULL REFERENCES service_types(id),
  passenger_user_id     uuid NOT NULL REFERENCES users(id),
  partner_user_id       uuid REFERENCES partners(user_id),  -- NULL until accepted
  status                text NOT NULL DEFAULT 'CRIADA' CHECK (status IN (
                          'CRIADA','BUSCANDO','OFERTADA','ACEITA','A_CAMINHO','CHEGOU','EM_VIAGEM',
                          'FINALIZADA','FALHA_PAGAMENTO','EXPIRADA',
                          'CANCELADA_CLIENTE','CANCELADA_PARCEIRO','CANCELADA_SISTEMA','CANCELADA_SUPORTE')),
  -- REQ-002/A4: immutable snapshot captured at acceptance; never recalculated
  pricing_mode_snapshot text CHECK (pricing_mode_snapshot IN ('PASSE','COMISSAO')),
  pass_id               uuid,                -- FK added below (partner_passes)
  pricing               jsonb NOT NULL,      -- {base, per_km, per_min, wait, surge, floor, fees}
  proposed_amount       numeric(10,2),       -- negociação (D2)
  fare_total            numeric(10,2) CHECK (fare_total >= 0),
  distance_km           numeric(7,2) CHECK (distance_km >= 0),
  origin                geography(Point, 4326) NOT NULL,
  destination           geography(Point, 4326) NOT NULL,
  origin_address        text,
  destination_address   text,
  requested_at          timestamptz NOT NULL DEFAULT now(),
  offered_at            timestamptz,
  accepted_at           timestamptz,
  arrived_at            timestamptz,
  started_at            timestamptz,
  finished_at           timestamptz,
  cancelled_at          timestamptz,
  -- REQ-002/A4 invariant: any state after acceptance requires the snapshot
  CONSTRAINT chk_snapshot_from_aceita CHECK (
    status NOT IN ('ACEITA','A_CAMINHO','CHEGOU','EM_VIAGEM','FINALIZADA','FALHA_PAGAMENTO')
    OR pricing_mode_snapshot IS NOT NULL),
  payment_status        text NOT NULL DEFAULT 'NOT_DUE'
                        CHECK (payment_status IN ('NOT_DUE','PENDING','CONFIRMED','FAILED','REFUNDED')),
  created_at            timestamptz NOT NULL DEFAULT now()
);
-- Dispatch hot path: only open rides matter
CREATE INDEX idx_rides_open ON rides (city_id, requested_at)
  WHERE status IN ('CRIADA','BUSCANDO','OFERTADA');
CREATE INDEX idx_rides_partner_active ON rides (partner_user_id)
  WHERE status IN ('ACEITA','A_CAMINHO','CHEGOU','EM_VIAGEM');
CREATE INDEX idx_rides_passenger_recent ON rides (passenger_user_id, created_at DESC);
CREATE INDEX idx_rides_origin_gist ON rides USING GIST (origin);

-- REQ-004/R7 (MVP-B): deliveries extend rides 1:1 (same core, service type)
CREATE TABLE deliveries (
  ride_id             uuid PRIMARY KEY REFERENCES rides(id) ON DELETE CASCADE,
  photos_required_min smallint NOT NULL DEFAULT 1 CHECK (photos_required_min BETWEEN 1 AND 3),
  photos_required_max smallint NOT NULL DEFAULT 3 CHECK (photos_required_max BETWEEN 1 AND 3),
  weight_kg           numeric(6,2),
  is_prohibited_flag  boolean NOT NULL DEFAULT false,  -- moderação sinalizou item
  recipient_pin_hash  text,                             -- PIN opcional do destinatário
  attempts            smallint NOT NULL DEFAULT 0,
  delivery_status     text NOT NULL DEFAULT 'FOTOS_PENDENTES' CHECK (delivery_status IN (
                        'FOTOS_PENDENTES','READY','COLETA_CONFIRMADA','EM_ROTA',
                        'TENTATIVA_FALHA','ENTREGUE','DEVOLUCAO'))
);

CREATE TABLE delivery_photos (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id       uuid NOT NULL REFERENCES deliveries(ride_id) ON DELETE CASCADE,
  kind          text NOT NULL CHECK (kind IN ('ITEM','PICKUP_PROOF','DELIVERY_PROOF')),
  storage_path  text NOT NULL,
  taken_at      timestamptz,
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT now() + interval '30 days'  -- LGPD
);
CREATE INDEX idx_delivery_photos_expiry ON delivery_photos (expires_at);

CREATE TABLE negotiations (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id             uuid NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  round_no            smallint NOT NULL,
  proposed_by_user_id uuid NOT NULL REFERENCES users(id),
  proposed_amount     numeric(10,2) NOT NULL CHECK (proposed_amount > 0),
  status              text NOT NULL DEFAULT 'OPEN'
                      CHECK (status IN ('OPEN','ACCEPTED','COUNTERED','EXPIRED','WITHDRAWN')),
  expires_at          timestamptz NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ride_id, round_no)
);

CREATE TABLE offers (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id           uuid NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  partner_user_id   uuid NOT NULL REFERENCES partners(user_id),
  sequence_no       smallint NOT NULL,
  offered_amount    numeric(10,2) NOT NULL,
  status            text NOT NULL DEFAULT 'SENT'
                    CHECK (status IN ('SENT','ACCEPTED','DECLINED','EXPIRED','REASSIGNED')),
  sent_at           timestamptz NOT NULL DEFAULT now(),
  timeout_at        timestamptz NOT NULL,    -- PRM-oferta.timeout (15s)
  responded_at      timestamptz,
  UNIQUE (ride_id, sequence_no)
);
CREATE INDEX idx_offers_partner_open ON offers (partner_user_id, sent_at DESC)
  WHERE status = 'SENT';

-- -----------------------------------------------------------------------------
-- Events & locations (partitioned; append-only)
-- -----------------------------------------------------------------------------
CREATE SEQUENCE ride_events_id_seq;
CREATE SEQUENCE ledger_entries_id_seq;

CREATE TABLE ride_events (
  ride_id          uuid NOT NULL,
  id               bigint NOT NULL DEFAULT nextval('ride_events_id_seq'),
  event_type       text NOT NULL,            -- catálogo ride.event.v1 (Parte 3/5)
  event_schema_ver smallint NOT NULL DEFAULT 1,
  payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
  actor_user_id    uuid,
  actor_role       text,
  idempotency_key  text NOT NULL,
  occurred_at      timestamptz NOT NULL,     -- quando aconteceu (cliente/servidor)
  received_at      timestamptz NOT NULL DEFAULT now(),  -- quando o servidor viu
  created_month    date NOT NULL DEFAULT date_trunc('month', now())::date,
  PRIMARY KEY (ride_id, id, created_month)
) PARTITION BY RANGE (created_month);
-- no FK to rides on purpose: hot-path inserts stay cheap; integrity via domain funs

CREATE TABLE partner_positions (
  partner_user_id  uuid NOT NULL,
  ts               timestamptz NOT NULL,
  pos              geography(Point, 4326) NOT NULL,
  speed_mps        real,
  accuracy_m       real,
  ride_id          uuid,
  PRIMARY KEY (partner_user_id, ts)
) PARTITION BY RANGE (ts);
-- Retention: 7d — old partitions are DROPPED, not deleted row-by-row.

-- -----------------------------------------------------------------------------
-- Money: payments, wallet, passes (REQ-002/003/010, ADR-003/005)
-- -----------------------------------------------------------------------------
CREATE TABLE payment_methods (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  method_type text NOT NULL CHECK (method_type IN ('PIX','CARD')),
  psp_token   text NOT NULL,                 -- tokenização do PSP; NUNCA PAN/CVV
  brand       text,
  last4       char(4),
  is_default  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE payments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id           uuid REFERENCES rides(id),
  payer_user_id     uuid NOT NULL REFERENCES users(id),
  method            text NOT NULL CHECK (method IN ('PIX','CARD','CASH')),
  amount            numeric(10,2) NOT NULL CHECK (amount >= 0),
  status            text NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','CONFIRMED','FAILED','REFUNDED','PARTIALLY_REFUNDED')),
  psp_provider      text NOT NULL,           -- 'pagarme' | 'asaas' (ADR-005)
  psp_payment_id    text,
  idempotency_key   text NOT NULL UNIQUE,    -- webhook reentrega não duplica
  expires_at        timestamptz,
  confirmed_at      timestamptz,
  refunded_amount   numeric(10,2) NOT NULL DEFAULT 0,
  raw_last_event    jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_payments_ride ON payments (ride_id);
CREATE UNIQUE INDEX uq_payments_psp ON payments (psp_provider, psp_payment_id)
  WHERE psp_payment_id IS NOT NULL;

CREATE TABLE partner_passes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_user_id   uuid NOT NULL REFERENCES partners(user_id),
  city_id           uuid NOT NULL REFERENCES cities(id),
  price_paid        numeric(10,2) NOT NULL CHECK (price_paid >= 0),
  duration_minutes  integer NOT NULL CHECK (duration_minutes > 0),
  status            text NOT NULL DEFAULT 'PENDING_PAYMENT'
                    CHECK (status IN ('PENDING_PAYMENT','SCHEDULED','ACTIVE','QUEUED','EXPIRED','REFUNDED')),
  counting_strategy text NOT NULL DEFAULT 'RELOGIO_CORRIDO'
                    CHECK (counting_strategy IN ('RELOGIO_CORRIDO','HORAS_ONLINE')),
  payment_id        uuid REFERENCES payments(id),
  queue_after_pass_id uuid REFERENCES partner_passes(id),  -- A3: fila FIFO
  starts_at         timestamptz,             -- ativação agendada (A2: 1º online)
  activated_at      timestamptz,
  expires_at        timestamptz,             -- relógio do SERVIDOR (A7)
  refunded_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
-- A6: uma compra pendente por parceiro (idempotência de UI)
CREATE UNIQUE INDEX uq_pass_pending_per_partner
  ON partner_passes (partner_user_id) WHERE status = 'PENDING_PAYMENT';
CREATE UNIQUE INDEX uq_pass_active_per_partner
  ON partner_passes (partner_user_id) WHERE status = 'ACTIVE';
ALTER TABLE rides ADD CONSTRAINT fk_rides_pass
  FOREIGN KEY (pass_id) REFERENCES partner_passes(id);
CREATE INDEX idx_passes_expiring ON partner_passes (expires_at)
  WHERE status IN ('ACTIVE','SCHEDULED');

-- Double-entry ledger (T6: append-only, idempotent, auditable)
CREATE TABLE ledger_accounts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_type    text NOT NULL CHECK (owner_type IN ('PLATFORM','PARTNER','PASSENGER')),
  owner_user_id uuid REFERENCES users(id),
  kind          text NOT NULL CHECK (kind IN (
                  'PSP_CASH','WALLET','REVENUE_PASSES','REVENUE_COMMISSION','REVENUE_FEES',
                  'REFUNDS','RECEIVABLE_CASH')),
  UNIQUE (owner_type, owner_user_id, kind)
);

CREATE TABLE ledger_entries (
  id              bigint NOT NULL DEFAULT nextval('ledger_entries_id_seq'),
  entry_group_id  uuid NOT NULL,             -- um evento de domínio = um grupo
  account_id      uuid NOT NULL REFERENCES ledger_accounts(id),
  ride_id         uuid,
  pass_id         uuid,
  direction       char(1) NOT NULL CHECK (direction IN ('D','C')),
  amount          numeric(12,2) NOT NULL CHECK (amount > 0),  -- sempre positivo
  description     text NOT NULL,
  idempotency_key text NOT NULL,
  created_month   date NOT NULL DEFAULT date_trunc('month', now())::date,  -- partition key
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_month)
) PARTITION BY RANGE (created_month);
-- Invariant 1 (property test): SUM over any partition = 0 (enforced app-side + reconciliação)

CREATE TABLE blocks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id),
  kind          text NOT NULL CHECK (kind IN ('CANCEL_ABUSE','KYC','SUPPORT','FRAUD','PAYMENT_DEBT')),
  reason        text NOT NULL,
  starts_at     timestamptz NOT NULL DEFAULT now(),
  ends_at       timestamptz,                 -- NULL = permanente (só suporte libera)
  created_by    uuid REFERENCES users(id),
  released_at   timestamptz,
  released_by   uuid REFERENCES users(id)
);
CREATE INDEX idx_blocks_active ON blocks (user_id) WHERE released_at IS NULL;

CREATE TABLE cancel_events (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id             uuid NOT NULL REFERENCES rides(id),
  cancelled_by_user_id uuid REFERENCES users(id),
  side                text NOT NULL CHECK (side IN ('PASSENGER','PARTNER','SYSTEM','SUPPORT')),
  reason_code         text NOT NULL,
  counts_as_fault     boolean NOT NULL,      -- R9: no-show/falha/emergência = false
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_cancel_passenger_7d ON cancel_events (cancelled_by_user_id, created_at)
  WHERE counts_as_fault AND side = 'PASSENGER';
CREATE INDEX idx_cancel_partner_7d ON cancel_events (cancelled_by_user_id, created_at)
  WHERE counts_as_fault AND side = 'PARTNER';

CREATE TABLE ratings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id       uuid NOT NULL REFERENCES rides(id),
  rater_user_id uuid NOT NULL REFERENCES users(id),
  rated_user_id uuid NOT NULL REFERENCES users(id),
  stars         smallint NOT NULL CHECK (stars BETWEEN 1 AND 5),
  tags          text[] NOT NULL DEFAULT '{}',
  comment       text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ride_id, rater_user_id)
);

-- -----------------------------------------------------------------------------
-- Support, notifications, audit (REQ-006/011, SEC)
-- -----------------------------------------------------------------------------
CREATE TABLE tickets (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id),
  ride_id           uuid REFERENCES rides(id),
  category          text NOT NULL CHECK (category IN (
                      'EMERGENCY','RIDE_ISSUE','PAYMENT','KYC','ACCOUNT','OTHER')),
  priority          text NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('EMERGENCY','NORMAL')),
  status            text NOT NULL DEFAULT 'OPEN'
                    CHECK (status IN ('OPEN','WAITING_AGENT','WAITING_USER','RESOLVED','CLOSED')),
  sla_due_at        timestamptz,
  assigned_agent_id uuid REFERENCES users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz
);
CREATE INDEX idx_tickets_queue ON tickets (priority, sla_due_at)
  WHERE status IN ('OPEN','WAITING_AGENT');

CREATE TABLE ticket_messages (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id     uuid NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
  author_user_id uuid REFERENCES users(id),
  author_role   text NOT NULL CHECK (author_role IN ('USER','BOT','AGENT','SYSTEM')),
  body          text NOT NULL,
  attachment_path text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_ticket_messages_thread ON ticket_messages (ticket_id, created_at);

CREATE TABLE notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel     text NOT NULL CHECK (channel IN ('PUSH','SMS','IN_APP')),
  type        text NOT NULL,                 -- ex.: 'PASS_EXPIRING_60M'
  payload     jsonb NOT NULL DEFAULT '{}'::jsonb,
  sent_at     timestamptz,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_notifications_unread ON notifications (user_id) WHERE read_at IS NULL;

CREATE TABLE audit_log (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_user_id uuid,
  action        text NOT NULL,               -- ex.: 'SUPPORT_FORGIVE_CANCEL'
  entity_type   text NOT NULL,
  entity_id     text NOT NULL,
  before_data   jsonb,
  after_data    jsonb,
  ip            inet,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Append-only guards (T6): no UPDATE/DELETE on ledgers/events/audit
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'Table % is append-only (T6)', TG_TABLE_NAME;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_ledger_entries_immutable
  BEFORE UPDATE OR DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_ride_events_immutable
  BEFORE UPDATE OR DELETE ON ride_events
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_audit_log_immutable
  BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- -----------------------------------------------------------------------------
-- Partition helpers (monthly events/ledger; daily positions + 7d retention)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ensure_monthly_partitions(p_table text, p_months int DEFAULT 3)
RETURNS void AS $$
DECLARE i int; d date;
BEGIN
  FOR i IN 0..p_months LOOP
    d := date_trunc('month', now())::date + (i || ' month')::interval;
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE c.relname = format('%s_%s', p_table, to_char(d,'YYYYMM'))
                     AND n.nspname = current_schema()) THEN
      EXECUTE format('CREATE TABLE %s_%s PARTITION OF %s FOR VALUES FROM (%L) TO (%L)',
        p_table, to_char(d,'YYYYMM'), p_table, d, d + interval '1 month');
      -- per-partition idempotency (documented trade-off: unique within partition)
      IF p_table IN ('ride_events','ledger_entries') THEN
        EXECUTE format('CREATE UNIQUE INDEX ON %s_%s (idempotency_key)',
          p_table, to_char(d,'YYYYMM'));
      END IF;
    END IF;
  END LOOP;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ensure_daily_positions(p_days int DEFAULT 2)
RETURNS void AS $$
DECLARE i int; d date;
BEGIN
  FOR i IN 0..p_days LOOP
    d := current_date + i;
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                   WHERE c.relname = format('partner_positions_%s', to_char(d,'YYYYMMDD'))
                     AND n.nspname = current_schema()) THEN
      EXECUTE format('CREATE TABLE partner_positions_%s PARTITION OF partner_positions
        FOR VALUES FROM (%L) TO (%L)',
        to_char(d,'YYYYMMDD'), d::timestamptz, (d + 1)::timestamptz);
      EXECUTE format('CREATE INDEX ON partner_positions_%s USING GIST (pos)',
        to_char(d,'YYYYMMDD'));
      EXECUTE format('CREATE INDEX ON partner_positions_%s (ts)',
        to_char(d,'YYYYMMDD'));
    END IF;
  END LOOP;
  -- retention: drop partitions older than 7 days (LGPD minimization)
  FOR d IN SELECT generate_series(current_date - 14, current_date - 8, '1 day')::date LOOP
    IF to_regclass(format('partner_positions_%s', to_char(d,'YYYYMMDD'))) IS NOT NULL THEN
      EXECUTE format('DROP TABLE partner_positions_%s', to_char(d,'YYYYMMDD'));
    END IF;
  END LOOP;
END; $$ LANGUAGE plpgsql;

SELECT ensure_monthly_partitions('ride_events');
SELECT ensure_monthly_partitions('ledger_entries');
SELECT ensure_daily_positions();

-- -----------------------------------------------------------------------------
-- Derived balances (never stored as source of truth; recomputed/reconciled)
-- -----------------------------------------------------------------------------
CREATE VIEW partner_wallet_balance AS
  SELECT a.owner_user_id AS partner_user_id,
         SUM(CASE WHEN e.direction = 'C' THEN e.amount ELSE -e.amount END) AS balance
  FROM ledger_entries e
  JOIN ledger_accounts a ON a.id = e.account_id
  WHERE a.owner_type = 'PARTNER' AND a.kind = 'WALLET'
  GROUP BY a.owner_user_id;

-- Retention jobs are scheduled by the platform (pg_cron or external scheduler) [VERIFICAR]:
--   SELECT ensure_daily_positions();                    -- a cada 6h
--   SELECT ensure_monthly_partitions('ride_events');    -- mensal
--   DELETE FROM delivery_photos WHERE expires_at < now(); (ou lifecycle no Storage)
--   DELETE FROM notifications WHERE created_at < now() - interval '90 days';
