import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { fetchWithTimeout } from "../_shared/http.ts";
import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";

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
    der,
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

  const response = await fetchWithTimeout("https://oauth2.googleapis.com/token", {
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
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
  let notificationId: string | undefined;

  try {
    const body = await req.json();
    const { user_id, title, body: msgBody, data } = body;
    notificationId = data?.notification_id?.toString();

    if (!user_id || !title || !msgBody) {
      return Response.json(
        { success: false, message: "user_id, title, and body are required" },
        { status: 400, headers: corsHeaders }
      );
    }

    // =====================================================
    // AUTH
    // Trusted server-side callers (the service-role key only -- used by the
    // DB trigger in deliver_push_notification_http_fnc) may target any
    // user_id. The anon key must NOT be treated as trusted: it ships in
    // every client's .env bundle, so accepting it here would let anyone who
    // extracted it bypass the ownership check below.
    // Any other caller must present a valid user session and may only
    // notify themselves.
    // =====================================================
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");
    if (!token) {
      return Response.json(
        { success: false, message: "Missing auth token" },
        { status: 401, headers: corsHeaders }
      );
    }

    const isTrustedServerCaller = token === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!isTrustedServerCaller) {
      const { data: authData, error: authError } = await supabase.auth.getUser(token);
      if (authError || !authData.user) {
        return Response.json(
          { success: false, message: "Unauthorized" },
          { status: 401, headers: corsHeaders }
        );
      }
      if (authData.user.id !== user_id) {
        return Response.json(
          { success: false, message: "Forbidden: cannot send notifications to another user" },
          { status: 403, headers: corsHeaders }
        );
      }
    }

    // =====================================================
    // PHASE 1 PRODUCTION CONTROL: server-side feature-flag enforcement
    // =====================================================
    // Placed after AUTH (not before) so this check runs only for an already-authorized caller --
    // consistent with every other business-logic check in this function (e.g. the per-user
    // pref_rating_notifications/pref_chat_notifications skip below). It is the single, central
    // outbound-push delivery point (every notification-triggering DB trigger funnels through
    // send_push_notification_fnc -> deliver_push_notification_http_fnc -> this function), so it is
    // the safest place to add a kill switch for actual FCM/APNs delivery. It does NOT, and cannot,
    // retroactively stop the public.notifications row itself -- that INSERT already happened
    // inside the same DB transaction that fired the trigger calling this function, before this
    // HTTP call was even made. Disabling notifications_enabled therefore stops push alerts only;
    // the in-app Notifications inbox (which reads straight from public.notifications) is
    // intentionally unaffected, so history is never lost by flipping this flag. A config-fetch
    // failure fails open (isFeatureEnabled defaults to true) so a production_config outage can
    // never itself silently swallow real notifications.
    //
    // Returns 200 (not an error status) when skipped: deliver_push_notification_http_fnc's
    // net.http_post call is fire-and-forget (pg_net, inside a plpgsql EXCEPTION-guarded block) and
    // never inspects the response body -- an intentional admin-controlled skip must not be
    // logged/surfaced as a delivery failure.
    const productionConfig = await getProductionConfig(supabase);
    if (!isFeatureEnabled(productionConfig, "notifications_enabled")) {
      console.log(`[SendPushNotification] Skipped: notifications_enabled=false (user_id=${user_id}, notification_id=${notificationId})`);
      return Response.json(
        { success: false, skipped: true, reason: "notifications_disabled" },
        { status: 200, headers: corsHeaders }
      );
    }

    const updateStatus = async (status: string, pushSent: boolean, error?: string) => {
      if (!notificationId) return;
      try {
        await supabase
          .from("notifications")
          .update({
            delivery_status: status,
            push_sent: pushSent,
            delivery_error: error || null
          })
          .eq("id", notificationId);
      } catch (err) {
        console.error("Failed to update notification status in DB:", err);
      }
    };

    // 1. Fetch user notification preferences
    const { data: userPref, error: userPrefError } = await supabase
      .from("users")
      .select("pref_order_notifications, pref_chat_notifications, pref_rating_notifications, pref_admin_notifications, order_notification_mode")
      .eq("id", user_id)
      .maybeSingle();

    if (userPrefError) {
      throw userPrefError;
    }

    const notificationType = data?.type?.toString();
    if (userPref) {
      if (notificationType === "chat_message" && !userPref.pref_chat_notifications) {
        await updateStatus("skipped", false);
        return Response.json(
          { success: true, message: "Chat notifications are disabled by the user." },
          { status: 200, headers: corsHeaders }
        );
      }
      if (notificationType === "new_rating" && !userPref.pref_rating_notifications) {
        await updateStatus("skipped", false);
        return Response.json(
          { success: true, message: "Rating notifications are disabled by the user." },
          { status: 200, headers: corsHeaders }
        );
      }
      if (notificationType === "order_assignment" && !userPref.pref_order_notifications) {
        await updateStatus("skipped", false);
        return Response.json(
          { success: true, message: "Order assignment notifications are disabled by the user." },
          { status: 200, headers: corsHeaders }
        );
      }
      if (notificationType === "order_status") {
        if (!userPref.pref_order_notifications) {
          await updateStatus("skipped", false);
          return Response.json(
            { success: true, message: "Order status notifications are disabled by the user." },
            { status: 200, headers: corsHeaders }
          );
        }

        const mode = userPref.order_notification_mode || "important_only";
        if (mode === "tracking_silent") {
          const status = data?.status?.toString();
          if (status !== "cancelled") {
            await updateStatus("skipped", false);
            return Response.json(
              { success: true, message: "Order status notification skipped under tracking_silent mode." },
              { status: 200, headers: corsHeaders }
            );
          }
        } else if (mode === "important_only") {
          const status = data?.status?.toString();
          const importantStatuses = ["accepted", "rider_arrived", "picked_up", "rider_at_drop", "completed", "delivered", "cancelled"];
          if (!status || !importantStatuses.includes(status)) {
            await updateStatus("skipped", false);
            return Response.json(
              { success: true, message: `Order status notification '${status}' skipped under important_only mode.` },
              { status: 200, headers: corsHeaders }
            );
          }
        }
      }
      if (notificationType === "admin_broadcast" && !userPref.pref_admin_notifications) {
        await updateStatus("skipped", false);
        return Response.json(
          { success: true, message: "Admin broadcast notifications are disabled by the user." },
          { status: 200, headers: corsHeaders }
        );
      }
    }

    // 2. Fetch active device tokens for the user
    const { data: tokens, error: tokensError } = await supabase
      .from("user_device_tokens")
      .select("fcm_token")
      .eq("user_id", user_id);

    if (tokensError) {
      throw tokensError;
    }

    if (!tokens || tokens.length === 0) {
      return Response.json(
        { success: true, message: "No registered device tokens for user." },
        { status: 200, headers: corsHeaders }
      );
    }

    // 3. Authenticate with Firebase Service Account Key
    const serviceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_KEY");
    if (!serviceAccountJson) {
      throw new Error("FIREBASE_SERVICE_ACCOUNT_KEY environment secret is not set.");
    }
    const serviceAccount = JSON.parse(serviceAccountJson);

    const accessToken = await getAccessToken(
      serviceAccount.client_email,
      serviceAccount.private_key
    );

    const projectId = serviceAccount.project_id;
    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

    const sendPromises = tokens.map(async (t) => {
      const isOrderAssignment = notificationType === "order_assignment";
      const collapseId = data?.order_id ? `order_${data.order_id}` : undefined;

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

      const res = await fetchWithTimeout(fcmUrl, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      }, 10000);

      const resText = await res.text();
      if (!res.ok) {
        console.error(`FCM error response for token ${t.fcm_token}: ${resText}`);
        
        // Auto-cleanup unregistered or invalid tokens
        if (resText.includes("UNREGISTERED") || res.status === 404 || res.status === 410) {
          console.log(`Cleaning up unregistered token: ${t.fcm_token}`);
          await supabase
            .from("user_device_tokens")
            .delete()
            .eq("fcm_token", t.fcm_token);
        }
      }
      return { token: t.fcm_token, status: res.status, ok: res.ok };
    });

    const results = await Promise.all(sendPromises);

    const anyOk = results.some((r) => r.ok);
    if (anyOk) {
      await updateStatus("sent", true);
    } else {
      await updateStatus("failed", false, "All token deliveries failed");
    }

    return Response.json(
      { success: true, results },
      { status: 200, headers: corsHeaders }
    );
  } catch (error) {
    console.error("PUSH NOTIFICATION ERROR =>", error);
    if (notificationId) {
      try {
        await supabase
          .from("notifications")
          .update({ delivery_status: "failed", push_sent: false, delivery_error: String(error) })
          .eq("id", notificationId);
      } catch (_) {}
    }
    return Response.json(
      { success: false, error: String(error) },
      { status: 500, headers: corsHeaders }
    );
  }
});
