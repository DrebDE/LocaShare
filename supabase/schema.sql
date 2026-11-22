-- LocaShare Family (Life360-Style Home Geofence & Away Tracking)
-- Supabase Free-Tier Cloud Schema (PostgreSQL 15+ with pgcrypto + SECURITY DEFINER RPCs)
--
-- Features:
--   - Zero-login privacy-first device registration (per-device 256-bit Bearer token hashed with SHA-256)
--   - Family Circles with shareable invite codes (FAM-XXXX-XXXX)
--   - Saved Places (Home, School, Work, Custom) with geofence radii & enter/exit alert toggles
--   - Home Privacy Masking + Smart Away Tracking (snaps coordinates to Home when inside Home geofence)
--   - Latest-only location storage (no continuous GPS breadcrumb trails) + Place enter/exit events
--   - Strict RLS deny-all on base tables; access mediated exclusively via authenticated RPCs

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ============================================================
-- Tables
-- ============================================================

CREATE TABLE IF NOT EXISTS public.devices (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id       TEXT NOT NULL UNIQUE,
    device_name     TEXT NOT NULL DEFAULT 'Android Phone',
    token_hash      TEXT NOT NULL,
    registered_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    unregistered_at TIMESTAMPTZ NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_devices_active ON public.devices (unregistered_at, device_id);

CREATE TABLE IF NOT EXISTS public.family_circles (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    circle_id            TEXT NOT NULL UNIQUE,
    name                 TEXT NOT NULL,
    invite_code          TEXT NOT NULL,
    invite_code_hash     TEXT NOT NULL UNIQUE,
    created_by_device_id BIGINT NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.circle_members (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    circle_id    BIGINT NOT NULL REFERENCES public.family_circles(id) ON DELETE CASCADE,
    device_id    BIGINT NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
    member_name  TEXT NOT NULL,
    role         TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member')),
    avatar_color TEXT NOT NULL DEFAULT '#0EA5E9',
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at      TIMESTAMPTZ NULL,
    UNIQUE (circle_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_circle_members_active ON public.circle_members (device_id, left_at);
CREATE INDEX IF NOT EXISTS idx_circle_members_circle ON public.circle_members (circle_id, left_at);

CREATE TABLE IF NOT EXISTS public.saved_places (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    place_id             TEXT NOT NULL UNIQUE,
    circle_id            BIGINT NOT NULL REFERENCES public.family_circles(id) ON DELETE CASCADE,
    name                 TEXT NOT NULL,
    category             TEXT NOT NULL DEFAULT 'custom' CHECK (category IN ('home', 'school', 'work', 'custom')),
    latitude             DOUBLE PRECISION NOT NULL CHECK (latitude BETWEEN -90 AND 90),
    longitude            DOUBLE PRECISION NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    radius_meters        INTEGER NOT NULL DEFAULT 150 CHECK (radius_meters BETWEEN 50 AND 5000),
    is_home              BOOLEAN NOT NULL DEFAULT FALSE,
    notify_on_enter      BOOLEAN NOT NULL DEFAULT TRUE,
    notify_on_exit       BOOLEAN NOT NULL DEFAULT TRUE,
    created_by_device_id BIGINT NULL REFERENCES public.devices(id) ON DELETE SET NULL,
    deleted_at           TIMESTAMPTZ NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_saved_places_circle ON public.saved_places (circle_id, deleted_at);

CREATE TABLE IF NOT EXISTS public.device_status (
    device_id            BIGINT PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
    sharing_enabled      BOOLEAN NOT NULL DEFAULT FALSE,
    status_state         TEXT NOT NULL DEFAULT 'registered',
    presence_mode        TEXT NOT NULL DEFAULT 'unknown' CHECK (presence_mode IN ('at_home', 'away', 'at_place', 'unknown')),
    current_place_id     TEXT NULL,
    current_place_name   TEXT NULL,
    home_privacy_masked  BOOLEAN NOT NULL DEFAULT FALSE,
    smart_home_mode      BOOLEAN NOT NULL DEFAULT TRUE,
    speed_mps            DOUBLE PRECISION NULL,
    battery_percentage   SMALLINT NULL,
    is_charging          BOOLEAN NULL,
    network_status       TEXT NOT NULL DEFAULT 'unknown',
    last_latitude        DOUBLE PRECISION NULL,
    last_longitude       DOUBLE PRECISION NULL,
    last_accuracy        DOUBLE PRECISION NULL,
    location_recorded_at TIMESTAMPTZ NULL,
    location_received_at TIMESTAMPTZ NULL,
    last_heartbeat_at    TIMESTAMPTZ NULL,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.place_events (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id       TEXT NOT NULL UNIQUE,
    circle_id      BIGINT NOT NULL REFERENCES public.family_circles(id) ON DELETE CASCADE,
    device_id      BIGINT NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
    member_name    TEXT NOT NULL,
    place_id       TEXT NOT NULL,
    place_name     TEXT NOT NULL,
    place_category TEXT NOT NULL DEFAULT 'custom',
    event_type     TEXT NOT NULL CHECK (event_type IN ('entered', 'exited')),
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_place_events_circle_time ON public.place_events (circle_id, occurred_at DESC);

CREATE TABLE IF NOT EXISTS public.push_tokens (
    device_id  BIGINT PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
    fcm_token  TEXT NOT NULL,
    platform   TEXT NOT NULL DEFAULT 'android',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- Row-Level Security (Strict Lock-Down)
-- All client operations flow through SECURITY DEFINER RPCs
-- that authenticate device_id + SHA-256(device_token).
-- ============================================================

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_circles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.circle_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_places ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.place_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- Internal Helpers
-- ============================================================

CREATE OR REPLACE FUNCTION public._locashare_sha256(p_secret TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT encode(extensions.digest(convert_to(COALESCE(p_secret, ''), 'UTF8'), 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION public._locashare_auth_device(p_device_id TEXT, p_device_token TEXT)
RETURNS public.devices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_hash TEXT;
BEGIN
    IF p_device_id IS NULL OR length(trim(p_device_id)) < 4 OR p_device_token IS NULL OR length(trim(p_device_token)) < 16 THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Missing or invalid device credentials.';
    END IF;

    v_hash := public._locashare_sha256(trim(p_device_token));

    SELECT * INTO v_dev
    FROM public.devices
    WHERE device_id = trim(p_device_id)
      AND unregistered_at IS NULL
    LIMIT 1;

    IF NOT FOUND OR v_dev.token_hash <> v_hash THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Invalid device token or unregistered device.';
    END IF;

    RETURN v_dev;
END;
$$;

CREATE OR REPLACE FUNCTION public._locashare_gen_invite_code()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_alphabet CONSTANT TEXT := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    v_bytes BYTEA := extensions.gen_random_bytes(8);
    v_raw TEXT := '';
    v_i INTEGER;
    v_idx INTEGER;
BEGIN
    FOR v_i IN 0..7 LOOP
        v_idx := (get_byte(v_bytes, v_i) % length(v_alphabet)) + 1;
        v_raw := v_raw || substr(v_alphabet, v_idx, 1);
    END LOOP;
    RETURN 'FAM-' || substr(v_raw, 1, 4) || '-' || substr(v_raw, 5, 4);
END;
$$;

CREATE OR REPLACE FUNCTION public._locashare_normalize_invite(p_input TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT regexp_replace(upper(trim(COALESCE(p_input, ''))), '[\s\-_]+', '', 'g');
$$;

-- ============================================================
-- Public RPCs (callable from Flutter & Android over HTTPS)
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_register_device(p_device_name TEXT DEFAULT 'Android Phone')
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_device_id TEXT := 'dev_' || encode(extensions.gen_random_bytes(12), 'hex');
    v_token TEXT := encode(extensions.gen_random_bytes(32), 'hex');
    v_token_hash TEXT := public._locashare_sha256(v_token);
    v_clean_name TEXT := left(COALESCE(NULLIF(trim(p_device_name), ''), 'Android Phone'), 64);
    v_db_id BIGINT;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    INSERT INTO public.devices (device_id, device_name, token_hash, registered_at, updated_at)
    VALUES (v_device_id, v_clean_name, v_token_hash, v_now, v_now)
    RETURNING id INTO v_db_id;

    INSERT INTO public.device_status (device_id, sharing_enabled, status_state, last_heartbeat_at, updated_at)
    VALUES (v_db_id, FALSE, 'registered', v_now, v_now);

    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', v_device_id,
        'device_name', v_clean_name,
        'device_token', v_token,
        'status_state', 'registered',
        'sharing_enabled', FALSE,
        'registered_at', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_get_circle_snapshot(
    p_device_id TEXT,
    p_device_token TEXT,
    p_events_since TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_circle RECORD;
    v_members JSONB := '[]'::JSONB;
    v_places JSONB := '[]'::JSONB;
    v_events JSONB := '[]'::JSONB;
    v_now TIMESTAMPTZ := NOW();
    v_online_sec CONSTANT INTEGER := 90;
    v_stale_sec CONSTANT INTEGER := 180;
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    SELECT fc.*, cm.member_name, cm.role
    INTO v_circle
    FROM public.circle_members cm
    JOIN public.family_circles fc ON fc.id = cm.circle_id
    WHERE cm.device_id = v_dev.id
      AND cm.left_at IS NULL
    ORDER BY cm.joined_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', TRUE,
            'circle', NULL,
            'members', '[]'::JSONB,
            'places', '[]'::JSONB,
            'events', '[]'::JSONB,
            'thresholds', jsonb_build_object(
                'online_threshold_seconds', v_online_sec,
                'location_stale_seconds', v_stale_sec
            ),
            'server_time', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        );
    END IF;

    SELECT COALESCE(jsonb_agg(m_obj ORDER BY m_sort DESC), '[]'::JSONB)
    INTO v_members
    FROM (
        SELECT
            (d.id = v_dev.id) AS m_sort,
            jsonb_build_object(
                'device_id', d.device_id,
                'device_name', d.device_name,
                'member_name', cm.member_name,
                'role', cm.role,
                'avatar_color', cm.avatar_color,
                'is_self', (d.id = v_dev.id),
                'sharing_enabled', ds.sharing_enabled,
                'status_state', CASE
                    WHEN ds.last_heartbeat_at IS NOT NULL
                         AND EXTRACT(EPOCH FROM (v_now - ds.last_heartbeat_at)) > v_online_sec
                        THEN 'offline'
                    ELSE ds.status_state
                END,
                'presence_mode', ds.presence_mode,
                'current_place_id', ds.current_place_id,
                'current_place_name', ds.current_place_name,
                'home_privacy_masked', ds.home_privacy_masked,
                'smart_home_mode', ds.smart_home_mode,
                'speed_mps', ds.speed_mps,
                'is_online', (
                    ds.last_heartbeat_at IS NOT NULL
                    AND EXTRACT(EPOCH FROM (v_now - ds.last_heartbeat_at)) <= v_online_sec
                    AND ds.status_state <> 'offline'
                ),
                'last_heartbeat_at', CASE
                    WHEN ds.last_heartbeat_at IS NOT NULL
                    THEN to_char(ds.last_heartbeat_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                    ELSE NULL
                END,
                'battery', ds.battery_percentage,
                'is_charging', ds.is_charging,
                'network_status', ds.network_status,
                'has_location', (ds.last_latitude IS NOT NULL AND ds.last_longitude IS NOT NULL),
                'is_location_fresh', (
                    ds.location_recorded_at IS NOT NULL
                    AND EXTRACT(EPOCH FROM (v_now - ds.location_recorded_at)) <= v_stale_sec
                ),
                'location', CASE
                    WHEN ds.last_latitude IS NOT NULL AND ds.last_longitude IS NOT NULL
                    THEN jsonb_build_object(
                        'latitude', ds.last_latitude,
                        'longitude', ds.last_longitude,
                        'accuracy', ds.last_accuracy,
                        'recorded_at', to_char(ds.location_recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                        'received_at', to_char(ds.location_received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                        'age_seconds', GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (v_now - ds.location_recorded_at)))::INTEGER),
                        'is_fresh', (EXTRACT(EPOCH FROM (v_now - ds.location_recorded_at)) <= v_stale_sec)
                    )
                    ELSE NULL
                END
            ) AS m_obj
        FROM public.circle_members cm
        JOIN public.devices d ON d.id = cm.device_id AND d.unregistered_at IS NULL
        JOIN public.device_status ds ON ds.device_id = d.id
        WHERE cm.circle_id = v_circle.id
          AND cm.left_at IS NULL
    ) sub;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'place_id', sp.place_id,
            'circle_id', v_circle.circle_id,
            'name', sp.name,
            'category', sp.category,
            'latitude', sp.latitude,
            'longitude', sp.longitude,
            'radius_meters', sp.radius_meters,
            'is_home', sp.is_home,
            'notify_on_enter', sp.notify_on_enter,
            'notify_on_exit', sp.notify_on_exit,
            'updated_at', to_char(sp.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ) ORDER BY sp.is_home DESC, sp.created_at ASC
    ), '[]'::JSONB)
    INTO v_places
    FROM public.saved_places sp
    WHERE sp.circle_id = v_circle.id
      AND sp.deleted_at IS NULL;

    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'event_id', pe.event_id,
            'device_id', d.device_id,
            'member_name', pe.member_name,
            'place_id', pe.place_id,
            'place_name', pe.place_name,
            'place_category', pe.place_category,
            'event_type', pe.event_type,
            'occurred_at', to_char(pe.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ) ORDER BY pe.occurred_at DESC
    ), '[]'::JSONB)
    INTO v_events
    FROM (
        SELECT *
        FROM public.place_events
        WHERE circle_id = v_circle.id
          AND (p_events_since IS NULL OR occurred_at > p_events_since)
        ORDER BY occurred_at DESC
        LIMIT 40
    ) pe
    JOIN public.devices d ON d.id = pe.device_id;

    RETURN jsonb_build_object(
        'success', TRUE,
        'circle', jsonb_build_object(
            'circle_id', v_circle.circle_id,
            'name', v_circle.name,
            'invite_code', v_circle.invite_code,
            'my_role', v_circle.role,
            'my_member_name', v_circle.member_name,
            'created_at', to_char(v_circle.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ),
        'members', v_members,
        'places', v_places,
        'events', v_events,
        'thresholds', jsonb_build_object(
            'online_threshold_seconds', v_online_sec,
            'location_stale_seconds', v_stale_sec
        ),
        'server_time', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_create_family_circle(
    p_device_id TEXT,
    p_device_token TEXT,
    p_circle_name TEXT,
    p_member_name TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_circle_id TEXT := 'cir_' || encode(extensions.gen_random_bytes(10), 'hex');
    v_invite TEXT := public._locashare_gen_invite_code();
    v_invite_norm TEXT := public._locashare_normalize_invite(v_invite);
    v_invite_hash TEXT := public._locashare_sha256(v_invite_norm);
    v_clean_circle TEXT := left(COALESCE(NULLIF(trim(p_circle_name), ''), 'Our Family'), 64);
    v_clean_member TEXT;
    v_circle_db_id BIGINT;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);
    v_clean_member := left(COALESCE(NULLIF(trim(p_member_name), ''), v_dev.device_name), 64);

    UPDATE public.circle_members
    SET left_at = v_now
    WHERE device_id = v_dev.id AND left_at IS NULL;

    INSERT INTO public.family_circles (circle_id, name, invite_code, invite_code_hash, created_by_device_id, created_at, updated_at)
    VALUES (v_circle_id, v_clean_circle, v_invite, v_invite_hash, v_dev.id, v_now, v_now)
    RETURNING id INTO v_circle_db_id;

    INSERT INTO public.circle_members (circle_id, device_id, member_name, role, avatar_color, joined_at, left_at)
    VALUES (v_circle_db_id, v_dev.id, v_clean_member, 'admin', '#0EA5E9', v_now, NULL);

    RETURN public.rpc_get_circle_snapshot(p_device_id, p_device_token, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_join_family_circle(
    p_device_id TEXT,
    p_device_token TEXT,
    p_invite_code TEXT,
    p_member_name TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_norm TEXT := public._locashare_normalize_invite(p_invite_code);
    v_hash TEXT := public._locashare_sha256(v_norm);
    v_circle_db_id BIGINT;
    v_clean_member TEXT;
    v_colors CONSTANT TEXT[] := ARRAY['#0EA5E9', '#10B981', '#8B5CF6', '#F59E0B', '#EC4899', '#06B6D4'];
    v_color TEXT;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    SELECT id INTO v_circle_db_id
    FROM public.family_circles
    WHERE invite_code_hash = v_hash
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_INVITE_CODE: Family invite code not found.';
    END IF;

    v_clean_member := left(COALESCE(NULLIF(trim(p_member_name), ''), v_dev.device_name), 64);
    v_color := v_colors[(((v_dev.id % array_length(v_colors, 1))::INTEGER) + 1)];

    UPDATE public.circle_members
    SET left_at = v_now
    WHERE device_id = v_dev.id AND circle_id <> v_circle_db_id AND left_at IS NULL;

    INSERT INTO public.circle_members (circle_id, device_id, member_name, role, avatar_color, joined_at, left_at)
    VALUES (v_circle_db_id, v_dev.id, v_clean_member, 'member', v_color, v_now, NULL)
    ON CONFLICT (circle_id, device_id) DO UPDATE
    SET member_name = EXCLUDED.member_name,
        left_at = NULL,
        joined_at = v_now;

    RETURN public.rpc_get_circle_snapshot(p_device_id, p_device_token, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_leave_family_circle(
    p_device_id TEXT,
    p_device_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    UPDATE public.circle_members
    SET left_at = NOW()
    WHERE device_id = v_dev.id AND left_at IS NULL;

    RETURN jsonb_build_object('success', TRUE, 'left', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_regenerate_circle_invite(
    p_device_id TEXT,
    p_device_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_circle_db_id BIGINT;
    v_invite TEXT := public._locashare_gen_invite_code();
    v_hash TEXT := public._locashare_sha256(public._locashare_normalize_invite(v_invite));
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    SELECT circle_id INTO v_circle_db_id
    FROM public.circle_members
    WHERE device_id = v_dev.id AND left_at IS NULL
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_IN_CIRCLE: Join or create a family circle first.';
    END IF;

    UPDATE public.family_circles
    SET invite_code = v_invite,
        invite_code_hash = v_hash,
        updated_at = NOW()
    WHERE id = v_circle_db_id;

    RETURN jsonb_build_object('success', TRUE, 'invite_code', v_invite);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_upsert_saved_place(
    p_device_id TEXT,
    p_device_token TEXT,
    p_place_id TEXT DEFAULT NULL,
    p_name TEXT DEFAULT 'Home',
    p_category TEXT DEFAULT 'custom',
    p_latitude DOUBLE PRECISION DEFAULT 0,
    p_longitude DOUBLE PRECISION DEFAULT 0,
    p_radius_meters INTEGER DEFAULT 150,
    p_is_home BOOLEAN DEFAULT FALSE,
    p_notify_on_enter BOOLEAN DEFAULT TRUE,
    p_notify_on_exit BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_circle_db_id BIGINT;
    v_cat TEXT := lower(trim(COALESCE(p_category, 'custom')));
    v_is_home BOOLEAN := COALESCE(p_is_home, FALSE) OR v_cat = 'home';
    v_radius INTEGER := LEAST(5000, GREATEST(50, COALESCE(p_radius_meters, 150)));
    v_name TEXT := left(COALESCE(NULLIF(trim(p_name), ''), CASE WHEN v_is_home THEN 'Home' ELSE 'Saved Place' END), 64);
    v_place_id TEXT := COALESCE(NULLIF(trim(p_place_id), ''), 'plc_' || encode(extensions.gen_random_bytes(10), 'hex'));
    v_now TIMESTAMPTZ := NOW();
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    IF p_latitude IS NULL OR p_longitude IS NULL OR p_latitude < -90 OR p_latitude > 90 OR p_longitude < -180 OR p_longitude > 180 THEN
        RAISE EXCEPTION 'INVALID_COORDINATES: Coordinates out of range.';
    END IF;

    IF v_cat NOT IN ('home', 'school', 'work', 'custom') THEN
        v_cat := 'custom';
    END IF;
    IF v_is_home THEN
        v_cat := 'home';
    END IF;

    SELECT circle_id INTO v_circle_db_id
    FROM public.circle_members
    WHERE device_id = v_dev.id AND left_at IS NULL
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_IN_CIRCLE: Join or create a family circle before saving places.';
    END IF;

    IF v_is_home THEN
        UPDATE public.saved_places
        SET is_home = FALSE, updated_at = v_now
        WHERE circle_id = v_circle_db_id AND is_home = TRUE AND deleted_at IS NULL AND place_id <> v_place_id;
    END IF;

    INSERT INTO public.saved_places (
        place_id, circle_id, name, category, latitude, longitude,
        radius_meters, is_home, notify_on_enter, notify_on_exit,
        created_by_device_id, deleted_at, created_at, updated_at
    ) VALUES (
        v_place_id, v_circle_db_id, v_name, v_cat, round(p_latitude::NUMERIC, 7)::DOUBLE PRECISION,
        round(p_longitude::NUMERIC, 7)::DOUBLE PRECISION, v_radius, v_is_home,
        COALESCE(p_notify_on_enter, TRUE), COALESCE(p_notify_on_exit, TRUE),
        v_dev.id, NULL, v_now, v_now
    )
    ON CONFLICT (place_id) DO UPDATE
    SET name = EXCLUDED.name,
        category = EXCLUDED.category,
        latitude = EXCLUDED.latitude,
        longitude = EXCLUDED.longitude,
        radius_meters = EXCLUDED.radius_meters,
        is_home = EXCLUDED.is_home,
        notify_on_enter = EXCLUDED.notify_on_enter,
        notify_on_exit = EXCLUDED.notify_on_exit,
        deleted_at = NULL,
        updated_at = v_now
    WHERE public.saved_places.circle_id = v_circle_db_id;

    RETURN public.rpc_get_circle_snapshot(p_device_id, p_device_token, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_delete_saved_place(
    p_device_id TEXT,
    p_device_token TEXT,
    p_place_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_circle_db_id BIGINT;
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    SELECT circle_id INTO v_circle_db_id
    FROM public.circle_members
    WHERE device_id = v_dev.id AND left_at IS NULL
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_IN_CIRCLE: Not a member of any circle.';
    END IF;

    UPDATE public.saved_places
    SET deleted_at = NOW(), updated_at = NOW()
    WHERE circle_id = v_circle_db_id AND place_id = trim(p_place_id) AND deleted_at IS NULL;

    RETURN public.rpc_get_circle_snapshot(p_device_id, p_device_token, NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_report_location(
    p_device_id TEXT,
    p_device_token TEXT,
    p_latitude DOUBLE PRECISION,
    p_longitude DOUBLE PRECISION,
    p_accuracy DOUBLE PRECISION DEFAULT NULL,
    p_recorded_at TIMESTAMPTZ DEFAULT NOW(),
    p_battery INTEGER DEFAULT NULL,
    p_is_charging BOOLEAN DEFAULT NULL,
    p_network_type TEXT DEFAULT 'unknown',
    p_presence_mode TEXT DEFAULT 'away',
    p_current_place_id TEXT DEFAULT NULL,
    p_current_place_name TEXT DEFAULT NULL,
    p_home_privacy_masked BOOLEAN DEFAULT FALSE,
    p_smart_home_mode BOOLEAN DEFAULT TRUE,
    p_speed_mps DOUBLE PRECISION DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_existing RECORD;
    v_now TIMESTAMPTZ := NOW();
    v_recorded TIMESTAMPTZ := COALESCE(p_recorded_at, v_now);
    v_lat DOUBLE PRECISION := round(p_latitude::NUMERIC, 7)::DOUBLE PRECISION;
    v_lng DOUBLE PRECISION := round(p_longitude::NUMERIC, 7)::DOUBLE PRECISION;
    v_presence TEXT := CASE
        WHEN p_presence_mode IN ('at_home', 'away', 'at_place', 'unknown') THEN p_presence_mode
        ELSE 'away'
    END;
    v_home RECORD;
    v_circle_db_id BIGINT;
    v_places JSONB := '[]'::JSONB;
    v_ignored BOOLEAN := FALSE;
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    IF p_latitude IS NULL OR p_longitude IS NULL OR p_latitude < -90 OR p_latitude > 90 OR p_longitude < -180 OR p_longitude > 180 THEN
        RAISE EXCEPTION 'INVALID_COORDINATES: Out of range.';
    END IF;
    IF v_recorded > (v_now + INTERVAL '5 minutes') THEN
        RAISE EXCEPTION 'INVALID_TIMESTAMP: Timestamp cannot be in the future.';
    END IF;

    SELECT circle_id INTO v_circle_db_id
    FROM public.circle_members
    WHERE device_id = v_dev.id AND left_at IS NULL
    LIMIT 1;

    -- Server-side Home privacy masking: snap indoor coordinates to Home geofence center
    IF COALESCE(p_home_privacy_masked, FALSE) AND v_presence = 'at_home' AND v_circle_db_id IS NOT NULL THEN
        SELECT latitude, longitude, place_id, name INTO v_home
        FROM public.saved_places
        WHERE circle_id = v_circle_db_id AND is_home = TRUE AND deleted_at IS NULL
        LIMIT 1;
        IF FOUND THEN
            v_lat := v_home.latitude;
            v_lng := v_home.longitude;
        END IF;
    END IF;

    SELECT location_recorded_at INTO v_existing
    FROM public.device_status
    WHERE device_id = v_dev.id;

    IF v_existing.location_recorded_at IS NOT NULL AND v_recorded < v_existing.location_recorded_at THEN
        v_ignored := TRUE;
        UPDATE public.device_status
        SET sharing_enabled = TRUE,
            status_state = 'sharing',
            battery_percentage = COALESCE(p_battery, battery_percentage),
            is_charging = COALESCE(p_is_charging, is_charging),
            network_status = COALESCE(NULLIF(trim(p_network_type), ''), network_status),
            last_heartbeat_at = v_now,
            updated_at = v_now
        WHERE device_id = v_dev.id;
    ELSE
        UPDATE public.device_status
        SET sharing_enabled = TRUE,
            status_state = 'sharing',
            presence_mode = v_presence,
            current_place_id = NULLIF(trim(COALESCE(p_current_place_id, '')), ''),
            current_place_name = NULLIF(trim(COALESCE(p_current_place_name, '')), ''),
            home_privacy_masked = COALESCE(p_home_privacy_masked, FALSE),
            smart_home_mode = COALESCE(p_smart_home_mode, TRUE),
            speed_mps = CASE WHEN COALESCE(p_home_privacy_masked, FALSE) THEN 0 ELSE p_speed_mps END,
            battery_percentage = COALESCE(p_battery, battery_percentage),
            is_charging = COALESCE(p_is_charging, is_charging),
            network_status = COALESCE(NULLIF(trim(p_network_type), ''), network_status),
            last_latitude = v_lat,
            last_longitude = v_lng,
            last_accuracy = p_accuracy,
            location_recorded_at = v_recorded,
            location_received_at = v_now,
            last_heartbeat_at = v_now,
            updated_at = v_now
        WHERE device_id = v_dev.id;
    END IF;

    IF v_circle_db_id IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'place_id', sp.place_id,
                'name', sp.name,
                'category', sp.category,
                'latitude', sp.latitude,
                'longitude', sp.longitude,
                'radius_meters', sp.radius_meters,
                'is_home', sp.is_home,
                'notify_on_enter', sp.notify_on_enter,
                'notify_on_exit', sp.notify_on_exit
            ) ORDER BY sp.is_home DESC, sp.created_at ASC
        ), '[]'::JSONB)
        INTO v_places
        FROM public.saved_places sp
        WHERE sp.circle_id = v_circle_db_id AND sp.deleted_at IS NULL;
    END IF;

    RETURN jsonb_build_object(
        'success', TRUE,
        'ignored_older_fix', v_ignored,
        'recorded_at', to_char(v_recorded AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'received_at', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'status_state', 'sharing',
        'presence_mode', v_presence,
        'places', v_places
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_report_heartbeat(
    p_device_id TEXT,
    p_device_token TEXT,
    p_sharing_enabled BOOLEAN DEFAULT TRUE,
    p_status_state TEXT DEFAULT 'sharing',
    p_battery INTEGER DEFAULT NULL,
    p_is_charging BOOLEAN DEFAULT NULL,
    p_network_type TEXT DEFAULT 'unknown',
    p_presence_mode TEXT DEFAULT NULL,
    p_current_place_id TEXT DEFAULT NULL,
    p_current_place_name TEXT DEFAULT NULL,
    p_smart_home_mode BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    UPDATE public.device_status
    SET sharing_enabled = COALESCE(p_sharing_enabled, sharing_enabled),
        status_state = COALESCE(NULLIF(trim(p_status_state), ''), status_state),
        battery_percentage = COALESCE(p_battery, battery_percentage),
        is_charging = COALESCE(p_is_charging, is_charging),
        network_status = COALESCE(NULLIF(trim(p_network_type), ''), network_status),
        presence_mode = CASE
            WHEN p_presence_mode IN ('at_home', 'away', 'at_place', 'unknown') THEN p_presence_mode
            ELSE presence_mode
        END,
        current_place_id = COALESCE(p_current_place_id, current_place_id),
        current_place_name = COALESCE(p_current_place_name, current_place_name),
        smart_home_mode = COALESCE(p_smart_home_mode, smart_home_mode),
        last_heartbeat_at = v_now,
        updated_at = v_now
    WHERE device_id = v_dev.id;

    RETURN jsonb_build_object(
        'success', TRUE,
        'last_heartbeat_at', to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_report_place_event(
    p_device_id TEXT,
    p_device_token TEXT,
    p_place_id TEXT,
    p_event_type TEXT,
    p_occurred_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_member RECORD;
    v_place RECORD;
    v_event_id TEXT := 'evt_' || encode(extensions.gen_random_bytes(10), 'hex');
    v_type TEXT := lower(trim(COALESCE(p_event_type, '')));
    v_occurred TIMESTAMPTZ := COALESCE(p_occurred_at, NOW());
    v_recent RECORD;
    v_tokens JSONB := '[]'::JSONB;
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    IF v_type NOT IN ('entered', 'exited') THEN
        RAISE EXCEPTION 'INVALID_EVENT_TYPE: Must be entered or exited.';
    END IF;

    SELECT circle_id, member_name INTO v_member
    FROM public.circle_members
    WHERE device_id = v_dev.id AND left_at IS NULL
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_IN_CIRCLE: Device does not belong to an active family circle.';
    END IF;

    SELECT * INTO v_place
    FROM public.saved_places
    WHERE place_id = trim(p_place_id)
      AND circle_id = v_member.circle_id
      AND deleted_at IS NULL
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'PLACE_NOT_FOUND: Saved place not found in your family circle.';
    END IF;

    -- Deduplicate identical transition within 30 seconds
    SELECT event_id INTO v_recent
    FROM public.place_events
    WHERE circle_id = v_member.circle_id
      AND device_id = v_dev.id
      AND place_id = v_place.place_id
      AND event_type = v_type
      AND occurred_at >= (v_occurred - INTERVAL '30 seconds')
    LIMIT 1;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', TRUE,
            'deduplicated', TRUE,
            'event_id', v_recent.event_id
        );
    END IF;

    INSERT INTO public.place_events (
        event_id, circle_id, device_id, member_name,
        place_id, place_name, place_category, event_type, occurred_at
    ) VALUES (
        v_event_id, v_member.circle_id, v_dev.id, v_member.member_name,
        v_place.place_id, v_place.name, v_place.category, v_type, v_occurred
    );

    IF v_type = 'entered' THEN
        UPDATE public.device_status
        SET presence_mode = CASE WHEN v_place.is_home OR v_place.category = 'home' THEN 'at_home' ELSE 'at_place' END,
            current_place_id = v_place.place_id,
            current_place_name = v_place.name,
            updated_at = NOW()
        WHERE device_id = v_dev.id;
    ELSE
        UPDATE public.device_status
        SET presence_mode = 'away',
            current_place_id = NULL,
            current_place_name = NULL,
            home_privacy_masked = FALSE,
            updated_at = NOW()
        WHERE device_id = v_dev.id;
    END IF;

    -- Prune events older than 14 days for this circle (privacy & free-tier hygiene)
    DELETE FROM public.place_events
    WHERE circle_id = v_member.circle_id
      AND occurred_at < (NOW() - INTERVAL '14 days');

    SELECT COALESCE(jsonb_agg(pt.fcm_token), '[]'::JSONB)
    INTO v_tokens
    FROM public.circle_members cm
    JOIN public.push_tokens pt ON pt.device_id = cm.device_id
    WHERE cm.circle_id = v_member.circle_id
      AND cm.left_at IS NULL
      AND cm.device_id <> v_dev.id;

    RETURN jsonb_build_object(
        'success', TRUE,
        'deduplicated', FALSE,
        'should_notify', CASE
            WHEN v_type = 'entered' THEN v_place.notify_on_enter
            ELSE v_place.notify_on_exit
        END,
        'event', jsonb_build_object(
            'event_id', v_event_id,
            'device_id', v_dev.device_id,
            'member_name', v_member.member_name,
            'place_id', v_place.place_id,
            'place_name', v_place.name,
            'place_category', v_place.category,
            'event_type', v_type,
            'occurred_at', to_char(v_occurred AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ),
        'recipient_fcm_tokens', v_tokens
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_register_push_token(
    p_device_id TEXT,
    p_device_token TEXT,
    p_fcm_token TEXT,
    p_platform TEXT DEFAULT 'android'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    INSERT INTO public.push_tokens (device_id, fcm_token, platform, updated_at)
    VALUES (v_dev.id, trim(p_fcm_token), left(COALESCE(NULLIF(trim(p_platform), ''), 'android'), 16), NOW())
    ON CONFLICT (device_id) DO UPDATE
    SET fcm_token = EXCLUDED.fcm_token,
        platform = EXCLUDED.platform,
        updated_at = NOW();

    RETURN jsonb_build_object('success', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_delete_device_location(
    p_device_id TEXT,
    p_device_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    UPDATE public.device_status
    SET last_latitude = NULL,
        last_longitude = NULL,
        last_accuracy = NULL,
        location_recorded_at = NULL,
        location_received_at = NULL,
        presence_mode = 'unknown',
        current_place_id = NULL,
        current_place_name = NULL,
        home_privacy_masked = FALSE,
        speed_mps = NULL,
        updated_at = NOW()
    WHERE device_id = v_dev.id;

    RETURN jsonb_build_object('success', TRUE, 'location_deleted', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_unregister_device(
    p_device_id TEXT,
    p_device_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_dev public.devices%ROWTYPE;
    v_now TIMESTAMPTZ := NOW();
BEGIN
    v_dev := public._locashare_auth_device(p_device_id, p_device_token);

    UPDATE public.devices
    SET unregistered_at = v_now,
        token_hash = 'REVOKED_' || encode(extensions.gen_random_bytes(16), 'hex'),
        updated_at = v_now
    WHERE id = v_dev.id;

    UPDATE public.circle_members
    SET left_at = v_now
    WHERE device_id = v_dev.id AND left_at IS NULL;

    UPDATE public.device_status
    SET sharing_enabled = FALSE,
        status_state = 'unregistered',
        last_latitude = NULL,
        last_longitude = NULL,
        last_accuracy = NULL,
        location_recorded_at = NULL,
        location_received_at = NULL,
        presence_mode = 'unknown',
        current_place_id = NULL,
        current_place_name = NULL,
        updated_at = v_now
    WHERE device_id = v_dev.id;

    DELETE FROM public.push_tokens WHERE device_id = v_dev.id;

    RETURN jsonb_build_object('success', TRUE, 'unregistered', TRUE, 'location_deleted', TRUE);
END;
$$;

-- Grant execute permissions to Supabase anon & authenticated roles
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT EXECUTE ON FUNCTION
    public.rpc_register_device(TEXT),
    public.rpc_get_circle_snapshot(TEXT, TEXT, TIMESTAMPTZ),
    public.rpc_create_family_circle(TEXT, TEXT, TEXT, TEXT),
    public.rpc_join_family_circle(TEXT, TEXT, TEXT, TEXT),
    public.rpc_leave_family_circle(TEXT, TEXT),
    public.rpc_regenerate_circle_invite(TEXT, TEXT),
    public.rpc_upsert_saved_place(TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER, BOOLEAN, BOOLEAN, BOOLEAN),
    public.rpc_delete_saved_place(TEXT, TEXT, TEXT),
    public.rpc_report_location(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, TIMESTAMPTZ, INTEGER, BOOLEAN, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, DOUBLE PRECISION),
    public.rpc_report_heartbeat(TEXT, TEXT, BOOLEAN, TEXT, INTEGER, BOOLEAN, TEXT, TEXT, TEXT, TEXT, BOOLEAN),
    public.rpc_report_place_event(TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ),
    public.rpc_register_push_token(TEXT, TEXT, TEXT, TEXT),
    public.rpc_delete_device_location(TEXT, TEXT),
    public.rpc_unregister_device(TEXT, TEXT)
TO anon, authenticated;
