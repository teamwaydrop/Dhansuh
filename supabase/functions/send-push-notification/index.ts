import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
import { fetchBufferedWithTimeout } from "../_shared/http.ts";
import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";
import { deliveryOutcome, retryAfter, notificationAllowed, type DeliveryOutcome } from "./delivery_result.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// PEM to DER helper for private keys
function pemToDer(pem: string): Uint8Array {
  const pemContents = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(pemContents);
  const len = binary.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// In-memory cache for the Google OAuth2 access token, reused across invocations that land on the
// same warm Edge Function instance. Deno Deploy/Supabase Edge Functions reuse the module scope
// (and this module-level variable) between requests on a warm instance, but each instance is
// otherwise independent and can vanish at any time -- a cold start simply finds this still null and
// falls through to the existing OAuth flow below, exactly as before this change.
let _cachedAccessToken: { token: string; expiresAtMs: number } | null = null;

// Refresh this many ms before the token's real expiry so a request that starts just before expiry
// can never end up using a token that goes stale mid-flight (Google tokens are minted with a 3600s
// lifetime -- see the `exp: now + 3600` claim below).
const TOKEN_REFRESH_MARGIN_MS = 5 * 60 * 1000;

// Generate Google OAuth2 access token using RS256 Web Crypto
async function getAccessToken(clientEmail: string, privateKey: string): Promise<string> {
  if (_cachedAccessToken && _cachedAccessToken.expiresAtMs - TOKEN_REFRESH_MARGIN_MS > Date.now()) {
    return _cachedAccessToken.token;
  }

  const cleanKey = privateKey.replace(/\\n/g, "\n");
  const der = pemToDer(cleanKey);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    new Uint8Array(der).buffer,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
    },
    false,
    ["sign"]
  );

  const header = {
    alg: "RS256",
    typ: "JWT",
  };

  const now = Math.floor(Date.now() / 1000);
  const claim = {
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    exp: now + 3600,
    iat: now,
  };

  const encoder = new TextEncoder();
  const encodedHeader = btoa(JSON.stringify(header)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const encodedClaim = btoa(JSON.stringify(claim)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const stringToSign = `${encodedHeader}.${encodedClaim}`;
  const data = encoder.encode(stringToSign);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, data);
  
  const encodedSignature = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");

  const jwt = `${stringToSign}.${encodedSignature}`;

  const response = await fetchBufferedWithTimeout("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  }, 10000);

  const resData = await response.json();
  if (!response.ok) {
    throw new Error(`Failed to get OAuth token: ${JSON.stringify(resData)}`);
  }

  const expiresInSec = typeof resData.expires_in === "number" ? resData.expires_in : 3600;
  _cachedAccessToken = {
    token: resData.access_token,
    expiresAtMs: Date.now() + expiresInSec * 1000,
  };

  return resData.access_token;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", {headers: corsHeaders});
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    {global: {fetch: (input: RequestInfo | URL, init?: RequestInit) => fetchBufferedWithTimeout(input, init ?? {}, 15000)}});
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const {data, error} = await supabase.rpc(name, args);
    if (error) throw new Error("DELIVERY_STORAGE_UNAVAILABLE");
    return data;
  };
  try {
    const body = await req.json();
    const notificationId = body.data?.notification_id?.toString();
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");
    if (!token) return Response.json({success:false}, {status:401,headers:corsHeaders});
    let actor: string|null = null;
    if (token !== Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) {
      const {data: authData, error} = await supabase.auth.getUser(token);
      if (error || !authData.user) return Response.json({success:false}, {status:401,headers:corsHeaders});
      actor = authData.user.id;
      if (body.user_id && actor !== body.user_id) return Response.json({success:false}, {status:403,headers:corsHeaders});
    }
    if (!notificationId) return Response.json({success:false,code:"PERSISTENT_NOTIFICATION_REQUIRED"}, {status:400,headers:corsHeaders});
    // Canonical recipient, title, body and devices come from one atomic DB claim.
    // The caller cannot substitute another user's payload or device registration.
    let claim;
    try { claim = await rpc("claim_notification_delivery", {p_id:notificationId,p_actor:actor}); }
    catch (_) { return Response.json({success:false,code:"DELIVERY_UNAVAILABLE"}, {status:503,headers:corsHeaders}); }
    const n = claim.notification;
    const devices = claim.devices ?? [];
    if (!devices.length) return Response.json({success:["sent","skipped"].includes(claim.state),state:claim.state,already_claimed_or_complete:true}, {status:["retry","pending","partial"].includes(claim.state)?202:200,headers:corsHeaders});
    const data = n.data;
    const title = n.title;
    const msgBody = n.body;
    const notificationType = String(data.type ?? "general");
    const finish = (d: any, result: DeliveryOutcome, delay=0) => rpc("finish_notification_device", {
      p_id:notificationId,p_device:d.device_id,p_registered:d.registered_at,p_token:d.token,p_result:result,p_retry_after:delay,
    });
    let allowed = true, accessToken = "", projectId = "";
    try {
      const productionConfig = await getProductionConfig(supabase);
      const {data:userPref,error} = await supabase.from("users")
        .select("pref_order_notifications,pref_chat_notifications,pref_rating_notifications,pref_admin_notifications,order_notification_mode")
        .eq("id",n.user_id).maybeSingle();
      if (error) throw error;
      allowed = isFeatureEnabled(productionConfig, "notifications_enabled") && notificationAllowed(notificationType,data,userPref);
      if (allowed) {
        const account = JSON.parse(Deno.env.get("FIREBASE_SERVICE_ACCOUNT_KEY")!);
        accessToken = await getAccessToken(account.client_email,account.private_key);
        projectId = account.project_id;
      }
    } catch (_) {
      await Promise.allSettled(devices.map((d:any)=>finish(d,"TRANSIENT")));
      return Response.json({success:false,retryable:true,code:"DELIVERY_PREPARATION_FAILED"}, {status:503,headers:corsHeaders});
    }
    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
    const settled = await Promise.allSettled(devices.map(async (d:any) => {
      if (!allowed) { await finish(d,"SKIPPED"); return {ok:false,status:200,skipped:true}; }
      if (!await rpc("begin_notification_device", {p_id:notificationId,p_device:d.device_id,p_registered:d.registered_at,p_token:d.token})) {
        return {ok:false,status:0,claim_expired:true};
      }
      const t = {fcm_token:d.fcm_token};
      const isOrderAssignment = notificationType === "order_assignment";
      const collapseId = data?.order_id ? `order_${data.order_id}` : `notification_${notificationId}`;

      const payload = {
        message: {
          token: t.fcm_token,
          notification: {
            title: title,
            body: msgBody,
          },
          android: {
            priority: "HIGH",
            notification: {
              sound: isOrderAssignment ? "order_nearby_sound" : "default",
              channel_id: isOrderAssignment ? "order_alerts_v2" : "high_importance_channel",
              notification_priority: "PRIORITY_MAX",
              default_sound: isOrderAssignment ? false : true,
              default_vibrate_timings: true,
              tag: collapseId,
              // Explicit per-message icon so background/killed-app notifications (rendered by the
              // OS directly from this payload, never touching notification_service.dart's
              // AndroidNotificationDetails) also show the WayDrop icon instead of falling back to
              // AndroidManifest's default_notification_icon indirection.
              icon: "ic_stat_notify",
              color: "#01205F",
            }
          },
          apns: {
            headers: {
              "apns-priority": "10",
              ...(collapseId ? { "apns-collapse-id": collapseId } : {}),
            },
            payload: {
              aps: {
                sound: isOrderAssignment ? "order_nearby_sound.aac" : "default",
                badge: 1,
              }
            }
          },
          data: data ? Object.fromEntries(
            Object.entries(data).map(([key, val]) => [key, String(val)])
          ) : {},
        },
      };

      let outcome: DeliveryOutcome = "UNCERTAIN", status = 0, delay = 0;
      try {
        const response = await fetchBufferedWithTimeout(fcmUrl, {method:"POST",headers:{"Authorization": `Bearer ${accessToken}`,"Content-Type":"application/json"},body:JSON.stringify(payload)},10000);
        status = response.status;
        outcome = deliveryOutcome(status, await response.text());
        delay = retryAfter(response.headers.get("Retry-After"));
        if (status===401) _cachedAccessToken = null;
      } catch (_) { /* Provider acceptance is unknown: never automatically resend. */ }
      const committed = await finish(d,outcome,delay);
      return {ok:outcome==="SENT" && committed===true,status,uncertain:outcome==="UNCERTAIN"};
    }));
    const results = settled.map((r)=>r.status==="fulfilled" ? r.value : {ok:false,status:0,durable_ack_pending:true});
    return Response.json({success:results.some((r)=>r.ok),results}, {headers:corsHeaders});
  } catch (_) {
    // No unscoped status write. Durable claims recover pre-send crashes and
    // quarantine ambiguous send-intent crashes without duplicating sends.
    return Response.json({success:false,code:"DELIVERY_STORAGE_UNAVAILABLE"}, {status:503,headers:corsHeaders});
  }
});
