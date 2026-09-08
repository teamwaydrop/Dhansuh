// supabase/functions/get-live-order-state/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { fetchWithTimeout } from "../_shared/http.ts";
import { getSignedRiderImageUrl } from "../_shared/signed_url_cache.ts";
import { getEtaWithBudget } from "../_shared/eta_cache.ts";
import { olaRequest } from "../_shared/ola_client.ts";

serve(async (req) => {
  try {
    // ---------------------------------------------------
    // CORS
    // ---------------------------------------------------

    if (req.method === "OPTIONS") {
      return new Response("ok", {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Headers":
            "authorization, x-client-info, apikey, content-type",
        },
      });
    }

    // ---------------------------------------------------
    // ENV VARIABLES
    // ---------------------------------------------------

    const supabaseUrl =
      Deno.env.get("SUPABASE_URL")!;

    const supabaseAnonKey =
      Deno.env.get("SUPABASE_ANON_KEY")!;

    const serviceRoleKey =
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // "oauth" (default) calls Ola Maps via OLA_CLIENT_ID/OLA_CLIENT_SECRET OAuth (see
    // _shared/ola_client.ts). Set to "api_key" (`supabase secrets set OLA_AUTH_MODE=api_key`) to
    // instantly revert to the pre-OAuth OLA_MAPS_API_KEY query-param path with zero redeploy, if
    // OAuth needs to be rolled back before it's been fully validated in production.
    const olaAuthMode =
      Deno.env.get("OLA_AUTH_MODE") ?? "oauth";

    // ---------------------------------------------------
    // AUTH HEADER
    // ---------------------------------------------------

    const authHeader =
      req.headers.get("Authorization");

    if (!authHeader) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Missing authorization header",
        }),
        {
          status: 401,
          headers: {
            "Content-Type": "application/json",
          },
        }
      );
    }

    // ---------------------------------------------------
    // USER CLIENT
    // ---------------------------------------------------

    const supabaseUserClient =
      createClient(
        supabaseUrl,
        supabaseAnonKey,
        {
          global: {
            headers: {
              Authorization: authHeader,
            },
          },
        }
      );

    // ---------------------------------------------------
    // ADMIN CLIENT
    // ---------------------------------------------------

    const supabaseAdmin =
      createClient(
        supabaseUrl,
        serviceRoleKey
      );

    // ---------------------------------------------------
    // BODY
    // ---------------------------------------------------

    const body = await req.json();

    const orderId = body.order_id;

    // ---------------------------------------------------
    // AUTH USER + GET ORDER -- run concurrently (Phase 10E 2E).
    //
    // The JWT-validation round trip and the embedded order fetch are independent: the order query
    // is a service-role read that never uses `user`, and the ownership check further below still
    // runs only after both resolve. One Promise.all removes a serial round trip from every ~5s
    // live-order poll. Guard precedence is unchanged (401 auth -> 400 order_id -> 404 -> 403); the
    // query is skipped when order_id is absent, and the embedded select below (order + rider +
    // rider_kyc + rider's user profile in one round trip) is unchanged. Same auth+fetch pattern
    // as update-order-status / accept-order / calculate-order-pricing.
    // ---------------------------------------------------

    const [
      { data: { user }, error: authError },
      { data: order, error: orderError },
    ] = await Promise.all([
      supabaseUserClient.auth.getUser(),
      orderId
        ? supabaseAdmin
        .from("orders")
        .select(`
          id,
          order_code,
          order_status,
          order_type,
          pickup_address,
          pickup_lat,
          pickup_lng,
          destination_address,
          destination_lat,
          destination_lng,
          rider_id,
          user_id,
          vehicle_type,
          pickup_otp,
          delivery_otp,
          created_at,
          riders (
            id,
            rating,
            current_lat,
            current_lng,
            current_heading,
            last_location_updated_at,
            user_id,
            rider_kyc!riders_kyc_id_fkey (
              vehicle_number,
              rider_image,
              vehicle_type
            ),
            users!riders_user_id_fkey (
              id,
              full_name,
              phone
            )
          )
        `)
        .eq("id", orderId)
        .single()
        : Promise.resolve({ data: null, error: null }),
    ]);

    if (authError || !user) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Unauthorized user",
        }),
        {
          status: 401,
          headers: {
            "Content-Type": "application/json",
          },
        }
      );
    }

    if (!orderId) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "order_id is required",
        }),
        {
          status: 400,
          headers: {
            "Content-Type": "application/json",
          },
        }
      );
    }

    if (orderError || !order) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Order not found",
        }),
        {
          status: 404,
          headers: {
            "Content-Type": "application/json",
          },
        }
      );
    }

    // ---------------------------------------------------
    // SECURITY CHECK
    // ---------------------------------------------------

    if (order.user_id !== user.id) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Access denied",
        }),
        {
          status: 403,
          headers: {
            "Content-Type": "application/json",
          },
        }
      );
    }

    // ---------------------------------------------------
    // RIDER NOT ASSIGNED
    // ---------------------------------------------------

    if (!order.rider_id) {
      return new Response(
        JSON.stringify({
          success: true,
          rider_assigned: false,
          order: {
            id: order.id,
            order_code: order.order_code,
            order_status: order.order_status,
            pickup_address:
              order.pickup_address,
            destination_address:
              order.destination_address,
            vehicle_type:
              order.vehicle_type,
          },
        }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
          },
        }
      );
    }

    // `order.riders` is populated by the embedded select above; the earlier "RIDER NOT ASSIGNED"
    // branch already returned when order.rider_id was null, so it is guaranteed non-null here
    // (a null embed alongside a non-null rider_id would indicate the rider row itself is missing,
    // preserved below with the same "Rider not found" 404 the old separate fetch produced).
    const rider = order.riders;

    if (!rider) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Rider not found",
        }),
        {
          status: 404,
          headers: {
            "Content-Type": "application/json",
          },
        }
      );
    }

    const riderUser = rider.users ?? null;

    console.log(
      "RIDER USER =>",
      riderUser
    );

    // ---------------------------------------------------
    // PHASE A (A2): rider live GPS -- PRIMARY public.rider_locations, FALLBACK the
    // embedded riders.current_* above.
    //
    // rider_locations is one-row-per-rider (rider_id PK), kept in sync with riders
    // by the A1 bridge trigger today and made the fresh high-frequency source by the
    // A3 Flutter writer; riders.current_* stays as a low-frequency compatibility
    // mirror (still read by dispatch / find_nearby_riders, unchanged here). This is
    // one small service-role point read (rider_id = PK), isolated: if it errors or
    // the row is missing / has no usable coordinates, `hasUsableRiderLocation` is
    // false and every downstream consumer falls back to exactly the riders.* values
    // used before A2 -- response shape, null handling and data exposed are identical
    // (rider_locations exposes the same four GPS fields riders already did).
    // ---------------------------------------------------
    const { data: riderLocationRow } = await supabaseAdmin
      .from("rider_locations")
      .select("current_lat, current_lng, current_heading, last_location_updated_at")
      .eq("rider_id", order.rider_id)
      .maybeSingle();

    const hasUsableRiderLocation =
      riderLocationRow != null &&
      riderLocationRow.current_lat != null &&
      riderLocationRow.current_lng != null;

    const effectiveRiderLat: number | null =
      hasUsableRiderLocation ? riderLocationRow!.current_lat : (rider.current_lat ?? null);
    const effectiveRiderLng: number | null =
      hasUsableRiderLocation ? riderLocationRow!.current_lng : (rider.current_lng ?? null);
    const effectiveRiderHeading: number | null =
      hasUsableRiderLocation ? riderLocationRow!.current_heading : (rider.current_heading ?? null);
    const effectiveRiderLocationUpdatedAt: string | null =
      hasUsableRiderLocation
        ? riderLocationRow!.last_location_updated_at
        : (rider.last_location_updated_at ?? null);

    // ---------------------------------------------------
    // ENRICHMENT: signed rider photo URL, the OLA Maps ETA, and the intercity plan vehicle-type
    // lookup are all independent of each other and of everything already fetched above -- run
    // concurrently. R7 perf fix: the intercity lookup used to be awaited sequentially before this
    // Promise.all even started, even though it depends only on order.order_type/orderId/rider.id
    // (already resolved above) and nothing here depends on its result -- folding it in removes one
    // full DB round trip from the critical path for intercity orders. Same query, same filters,
    // same null fallback, same downstream usage; only when it runs relative to the other two
    // changed. Both cache-backed lookups are also routed through short-lived isolate-scoped caches
    // (_shared/signed_url_cache.ts, _shared/eta_cache.ts) so repeated 5s polls for the same order
    // don't each pay for a fresh storage-sign call or a fresh OLA Maps round trip; same final
    // values, same fallback-on-error behavior either way -- only how often the underlying work
    // actually happens changed.
    // ---------------------------------------------------
    const [resolvedRiderImage, etaResult, intercityPlanVehicleType] = await Promise.all([
      // RESOLVE RIDER PHOTO (P1-2 fix: rider_kyc bucket is now private -- a stored
      // value may be either the OLD full public-URL shape or a NEW bare storage path;
      // either way it must be turned into a fresh signed URL here, server-side, using
      // supabaseAdmin (service-role, unaffected by storage RLS) so the client never
      // needs its own signed-URL round trip for this field.
      (async (): Promise<string | null> => {
        const storedRiderImage: string | null = rider.rider_kyc?.rider_image ?? null;
        if (!storedRiderImage) return null;
        const publicUrlMarker = "/storage/v1/object/public/rider_kyc/";
        const storagePath = storedRiderImage.includes(publicUrlMarker)
          ? storedRiderImage.split(publicUrlMarker).pop()!
          : (storedRiderImage.startsWith("http://") || storedRiderImage.startsWith("https://"))
            ? null
            : storedRiderImage;
        if (!storagePath) return null;
        return await getSignedRiderImageUrl(supabaseAdmin, storagePath);
      })(),

      // ETA CALCULATION USING OLA MAPS -- own try/catch preserved exactly as before (a slow/failed
      // OLA call must never fail the whole response, unchanged).
      // getEtaWithBudget adds a short-TTL cache + a 2s race bound in front of this same fetch --
      // see _shared/eta_cache.ts for why fetchFresh must throw (not return a value) on failure.
      getEtaWithBudget(orderId, async () => {
          // A2: rider_locations-first, riders.* fallback (resolved above).
          const riderLat = effectiveRiderLat;
          const riderLng = effectiveRiderLng;
          const pickupLat = order.pickup_lat;
          const pickupLng = order.pickup_lng;
          try {
            // deno-lint-ignore no-explicit-any
            let etaData: any;
            if (olaAuthMode === "api_key") {
              // Legacy path, preserved byte-for-byte -- see OLA_AUTH_MODE comment above.
              const olaApiKey = Deno.env.get("OLA_MAPS_API_KEY") ?? "";
              const etaResponse = await fetchWithTimeout(
                `https://api.olamaps.io/routing/v1/distanceMatrix/basic?origins=${riderLat},${riderLng}&destinations=${pickupLat},${pickupLng}&api_key=${olaApiKey}`,
                {
                  method: "GET",
                  headers: {
                    "X-Request-Id": crypto.randomUUID(),
                  },
                },
                8000,
              );
              etaData = await etaResponse.json();
              if (!etaResponse.ok) {
                const apiMessage = (etaData && (etaData.error_message || etaData.message || etaData.status)) || "no error detail in body";
                throw new Error(`OLA API HTTP error ${etaResponse.status}: ${apiMessage}`);
              }
            } else {
              // OAuth path (default): getOlaAccessToken()/olaRequest() handle token
              // acquisition/caching/retry and throw an HttpError with a safe message on failure --
              // caught below exactly like the legacy branch's thrown Error.
              etaData = await olaRequest("/routing/v1/distanceMatrix/basic", {
                query: {
                  origins: `${riderLat},${riderLng}`,
                  destinations: `${pickupLat},${pickupLng}`,
                },
                timeoutMs: 8000,
              });
            }
            console.log("OLA ETA RESPONSE =>", etaData);

            // DEFENSIVE VALIDATION (OLA ETA parsing crash fix, 2026-08-08): the unguarded
            // `etaData.rows[0].elements[0]` access below crashed with a generic, unactionable
            // TypeError on every single call in the latest real-device session (25/25 failures) --
            // an HTTP error response from OLA (bad/expired key, quota, rejected request) and a
            // differently-shaped success body both land here with no usable `rows` array, and were
            // previously indistinguishable from each other or from a genuine parsing bug. Each
            // branch below now throws a specific, descriptive error instead of letting the access
            // crash, so the *reason* is captured in the caught error's message below -- no raw
            // response-body log access needed to tell the causes apart. The catch block's re-throw,
            // getEtaWithBudget's fallback, and the success-path computation/shape below are all
            // unchanged.
            const rows = etaData?.rows;
            if (!Array.isArray(rows) || rows.length === 0) {
              const apiMessage = (etaData && (etaData.error_message || etaData.message || etaData.status)) || "rows missing/empty";
              throw new Error(`OLA ETA response has no rows: ${apiMessage}`);
            }

            const elements = rows[0]?.elements;
            if (!Array.isArray(elements) || elements.length === 0) {
              throw new Error("OLA ETA response row has no elements");
            }

            const element = elements[0];
            if (!element || typeof element.distance !== "number" || typeof element.duration !== "number") {
              const elementStatus = element?.status ?? "unknown";
              throw new Error(`OLA ETA element missing distance/duration (status: ${elementStatus})`);
            }

            return {
              distanceKm: element.distance / 1000,
              estimatedArrivalMinutes: Math.max(1, Math.round(element.duration / 60)),
            };
          } catch (etaError) {
            console.error("ETA CALCULATION ERROR =>", etaError);
            // Re-throw (rather than returning a zero fallback here) so getEtaWithBudget's own
            // cache-miss fallback runs -- serving the last good cached ETA instead of clobbering
            // it with a zero for the full cache TTL after one transient OLA failure. If there is
            // no cache yet, getEtaWithBudget itself returns the identical zero-value fallback.
            throw etaError;
          }
        }),

      // INTERCITY VEHICLE TYPE (Issue 3 fix): orders.vehicle_type for an intercity_ride/
      // intercity_parcel order is the PASSENGER'S preference captured at request-creation time
      // (create-order/index.ts normalizes it to 'any'/'bike'/'auto'/'cab' before a traveller is
      // even matched) -- it is never the traveller's actual vehicle, so it must never be shown to
      // the passenger as "the rider's vehicle". Once a traveller is matched, rider_travel_plans.
      // vehicle_type (the specific plan/vehicle the traveller published and the passenger actually
      // booked onto) is the authoritative value -- rider_kyc.vehicle_type is not used here because
      // a traveller can own or be KYC-verified for a different vehicle than the one they published
      // for this particular trip. Scoped strictly to intercity order types so local ride/parcel
      // vehicle_type (which IS already the real, dispatch-matched vehicle) is completely unaffected.
      (async (): Promise<string | null> => {
        if (order.order_type === "intercity_ride" || order.order_type === "intercity_parcel") {
          const { data: intercityRequest } = await supabaseAdmin
            .from("intercity_requests")
            .select("rider_travel_plans!intercity_requests_route_id_fkey(vehicle_type)")
            .eq("parcel_id", orderId)
            .eq("traveller_id", rider.id)
            .not("route_id", "is", null)
            .order("updated_at", { ascending: false })
            .limit(1)
            .maybeSingle();

          return (intercityRequest as { rider_travel_plans?: { vehicle_type?: string | null } | null } | null)
            ?.rider_travel_plans?.vehicle_type ?? null;
        }
        return null;
      })(),
    ]);

    const { distanceKm, estimatedArrivalMinutes, degraded: etaDegraded } = etaResult;

    // ---------------------------------------------------
    // RESPONSE
    // ---------------------------------------------------

    return new Response(
      JSON.stringify({
        success: true,

        rider_assigned: true,

        order: {
          id: order.id,
          order_code:
            order.order_code,
          order_status:
            order.order_status,

          pickup_address:
            order.pickup_address,

          pickup_lat:
            order.pickup_lat,

          pickup_lng:
            order.pickup_lng,

          destination_address:
            order.destination_address,

          destination_lat:
            order.destination_lat,

          destination_lng:
            order.destination_lng,

          vehicle_type:
            intercityPlanVehicleType ?? order.vehicle_type,

          created_at:
            order.created_at,
        },

        rider: {
          id: rider.id,

         name:
  riderUser?.full_name ??
  "Waydrop Rider",

phone:
  riderUser?.phone ?? "",

          image:
            resolvedRiderImage,

          vehicle_number:
            rider.rider_kyc
              ?.vehicle_number ?? null,

          vehicle_type:
            intercityPlanVehicleType ?? rider.rider_kyc?.vehicle_type ?? null,

          rating:
            rider.rating,
        },

        live_location: {
          // A2: rider_locations-first, riders.* fallback (resolved above).
          latitude:
            effectiveRiderLat,

          longitude:
            effectiveRiderLng,

          heading:
            effectiveRiderHeading,

          updated_at:
            effectiveRiderLocationUpdatedAt,
        },

        tracking: {
          distance_to_pickup_km:
            Number(
              distanceKm.toFixed(2)
            ),

          estimated_arrival_minutes:
            estimatedArrivalMinutes,

          // P1 fix (ETA failure must not break live ride status): true only when the ETA
          // provider (OLA Maps) failed or didn't answer in time and the value above is a
          // fallback (last-known-good cache, or 0/0 if there's no cache yet) rather than a
          // fresh reading -- order/rider/status data above this point is completely unaffected
          // either way. Omitted (undefined, not false) on a normal successful ETA so existing
          // clients that don't read this field see byte-for-byte the same shape as before.
          tracking_degraded:
            etaDegraded === true ? true : undefined,
        },
      }),
      {
        status: 200,
        headers: {
          "Content-Type":
            "application/json",

          "Access-Control-Allow-Origin":
            "*",
        },
      }
    );

  } catch (error) {

    console.error(
      "GET LIVE ORDER STATE ERROR =>",
      error
    );

    return new Response(
      JSON.stringify({
        success: false,
        error: String(error),
      }),
      {
        status: 500,
        headers: {
          "Content-Type":
            "application/json",
        },
      }
    );
  }
});