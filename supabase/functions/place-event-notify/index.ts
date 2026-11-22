// LocaShare Family — Supabase Edge Function: place-event-notify
//
// Authenticates the calling device via `rpc_report_place_event` (or accepts
// a trusted Supabase Database Webhook payload on `place_events` INSERT) and
// sends Firebase Cloud Messaging (FCM HTTP v1) push notifications to all other
// family circle members who registered an FCM push token.
//
// Required Supabase Function Secrets (set via `supabase secrets set`):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY   (only needed for webhook mode)
//   FCM_PROJECT_ID              (Firebase project ID)
//   FCM_CLIENT_EMAIL            (Firebase service account client_email)
//   FCM_PRIVATE_KEY             (Firebase service account PEM private_key)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

interface NotifyRequest {
  device_id?: string;
  device_token?: string;
  place_id?: string;
  event_type?: "entered" | "exited";
  occurred_at?: string;
}

function base64UrlEncode(data: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < data.length; i++) {
    binary += String.fromCharCode(data[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const clean = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

async function getGoogleAccessToken(
  clientEmail: string,
  privateKeyPem: string,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })),
  );
  const claim = base64UrlEncode(
    new TextEncoder().encode(
      JSON.stringify({
        iss: clientEmail,
        scope: "https://www.googleapis.com/auth/firebase.messaging",
        aud: "https://oauth2.googleapis.com/token",
        iat: now,
        exp: now + 3600,
      }),
    ),
  );
  const unsigned = `${header}.${claim}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${base64UrlEncode(new Uint8Array(sig))}`;

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!tokenRes.ok) {
    throw new Error(`OAuth token exchange failed: ${tokenRes.status}`);
  }
  const tokenJson = await tokenRes.json();
  return tokenJson.access_token as string;
}

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ success: false, error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const supabaseUrl = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const body = (await req.json()) as NotifyRequest;

    if (!body.device_id || !body.device_token || !body.place_id || !body.event_type) {
      return new Response(
        JSON.stringify({ success: false, error: "Missing required fields." }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    // Validate device credentials & persist deduplicated place event via Postgres RPC
    const rpcRes = await fetch(`${supabaseUrl}/rest/v1/rpc/rpc_report_place_event`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: anonKey,
        Authorization: `Bearer ${anonKey}`,
      },
      body: JSON.stringify({
        p_device_id: body.device_id,
        p_device_token: body.device_token,
        p_place_id: body.place_id,
        p_event_type: body.event_type,
        p_occurred_at: body.occurred_at ?? new Date().toISOString(),
      }),
    });

    const rpcData = await rpcRes.json();
    if (!rpcRes.ok) {
      return new Response(
        JSON.stringify({ success: false, error: rpcData?.message ?? "RPC failed" }),
        { status: rpcRes.status, headers: { "Content-Type": "application/json" } },
      );
    }

    if (rpcData.deduplicated || !rpcData.should_notify) {
      return new Response(
        JSON.stringify({ ...rpcData, push_sent: 0 }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    const fcmProjectId = Deno.env.get("FCM_PROJECT_ID") ?? "";
    const fcmEmail = Deno.env.get("FCM_CLIENT_EMAIL") ?? "";
    const fcmPrivateKey = Deno.env.get("FCM_PRIVATE_KEY") ?? "";
    const tokens: string[] = Array.isArray(rpcData.recipient_fcm_tokens)
      ? rpcData.recipient_fcm_tokens
      : [];

    let sent = 0;
    if (fcmProjectId && fcmEmail && fcmPrivateKey && tokens.length > 0) {
      const accessToken = await getGoogleAccessToken(fcmEmail, fcmPrivateKey);
      const evt = rpcData.event ?? {};
      const verb = evt.event_type === "exited" ? "left" : "arrived at";
      const title = `${evt.member_name ?? "Family member"} ${verb} ${evt.place_name ?? "place"}`;
      const bodyText =
        evt.place_category === "home" && evt.event_type === "exited"
          ? "Live away-from-home tracking is now active."
          : evt.place_category === "home" && evt.event_type === "entered"
            ? "Arrived safely at Home (Battery Saver mode active)."
            : `Updated at ${evt.occurred_at ?? "just now"}`;

      for (const token of tokens) {
        const res = await fetch(
          `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(fcmProjectId)}/messages:send`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${accessToken}`,
            },
            body: JSON.stringify({
              message: {
                token,
                notification: { title, body: bodyText },
                data: {
                  event_id: String(evt.event_id ?? ""),
                  place_id: String(evt.place_id ?? ""),
                  place_name: String(evt.place_name ?? ""),
                  event_type: String(evt.event_type ?? ""),
                  member_name: String(evt.member_name ?? ""),
                },
                android: {
                  priority: "high",
                  notification: { channel_id: "locashare_family_alerts_channel" },
                },
              },
            }),
          },
        );
        if (res.ok) sent++;
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        event: rpcData.event,
        push_sent: sent,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ success: false, error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
