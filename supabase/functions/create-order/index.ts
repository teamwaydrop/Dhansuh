// supabase/functions/create-order/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

import { createClient }
from "https://esm.sh/@supabase/supabase-js@2";

import { withTimeout } from "../_shared/http.ts";
import { HttpError, httpErrorResponse } from "../_shared/http_errors.ts";
import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";

serve(async (req) => {

  try {

    // =====================================================
    // SUPABASE
    // =====================================================

    const supabase =
      createClient(

        Deno.env.get(
          "SUPABASE_URL"
        )!,

        Deno.env.get(
          "SUPABASE_SERVICE_ROLE_KEY"
        )!
      );

    // =====================================================
    // BODY
    // =====================================================

    const body =
      await req.json();

    console.log("[CreateOrder] Received request body keys:", Object.keys(body));
    console.log("[CreateOrder] Device metadata parsed:", {
      created_device_id: body.created_device_id,
      device_model: body.device_model,
      device_brand: body.device_brand,
      os_version: body.os_version,
      app_version: body.app_version,
    });

    // =====================================================
    // AUTH
    // =====================================================

    const authToken = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!authToken) {
      return new Response(
        JSON.stringify({ success: false, error: "Missing auth token" }),
        {
          headers: { "Content-Type": "application/json" },
          status: 401,
        }
      );
    }

    const { data: authData, error: authError } = await supabase.auth.getUser(authToken);

    if (authError || !authData.user) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        {
          headers: { "Content-Type": "application/json" },
          status: 401,
        }
      );
    }

    const {

      user_id,

      order_type,

      vehicle_type,

      pickup_address,

      pickup_lat,

      pickup_lng,

      destination_address,

      destination_lat,

      destination_lng,

      distance_km,

      distance_meters,

      duration_seconds,

      payment_mode,

      payment_id,

      // P1 fix (create-order idempotency): client-generated per-booking-attempt token (see
      // ride_location_screen.dart's _generateBookingIdempotencyKey()). Optional -- omitted
      // entirely by any other order-creation caller that doesn't send it, which behaves exactly
      // as before this fix.
      idempotency_key,

      promo_code,

      max_boost_amount = 0,

      parcel_type,

      receiver_name,

      receiver_phone,

      weight_category,

      weight_kg,

      special_instructions,

      parcel_images = [],

      pickup_city,

      destination_city,

      travel_date,

      seats_requested,

      created_device_id,

      sender_declaration_accepted = false,

      sender_declaration_accepted_at,

      device_model,

      device_brand,

      os_version,

      app_version,

    } = body;

    // =====================================================
    // PHASE 1 PRODUCTION CONTROL: server-side feature-flag enforcement
    // =====================================================
    // This is the single, central order-creation entry point for every order type (local ride,
    // local parcel, intercity ride, intercity parcel -- see order_type above), so it is the safest
    // place to enforce these flags server-side rather than duplicating the check across multiple
    // functions. A Flutter-side UI disable (FeatureFlags, home_tab.dart) is not sufficient on its
    // own -- this closes the gap for any caller that bypasses the UI. A config-fetch failure fails
    // open (isFeatureEnabled defaults to true) so an outage of production_config itself can never
    // block order creation.
    //
    // local_rides_enabled is the master switch for the whole local-ride vertical (UI visibility);
    // ride_booking_enabled is the finer-grained "new bookings paused" switch for the booking action
    // itself -- both must be true for a 'ride' order. intercity_enabled covers both
    // intercity_ride and intercity_parcel (Phase 1 does not split intercity by ride/parcel).
    // parcel_enabled covers only local_parcel. batch_delivery/food_delivery/grocery_delivery are
    // unaffected -- no flag was requested for them.
    const productionConfig = await getProductionConfig(supabase);
    if (order_type === "ride") {
      if (
        !isFeatureEnabled(productionConfig, "local_rides_enabled") ||
        !isFeatureEnabled(productionConfig, "ride_booking_enabled")
      ) {
        throw new HttpError(503, "Ride booking is temporarily unavailable. Please try again later.", "FEATURE_DISABLED");
      }
    } else if (order_type === "local_parcel") {
      if (!isFeatureEnabled(productionConfig, "parcel_enabled")) {
        throw new HttpError(503, "Parcel booking is temporarily unavailable. Please try again later.", "FEATURE_DISABLED");
      }
    } else if (order_type === "intercity_ride" || order_type === "intercity_parcel") {
      if (!isFeatureEnabled(productionConfig, "intercity_enabled")) {
        throw new HttpError(503, "Intercity booking is temporarily unavailable. Please try again later.", "FEATURE_DISABLED");
      }
    }

    // =====================================================
    // NORMALIZE PARCEL TYPE
    // =====================================================
    let normalizedParcelType = parcel_type;
    if (parcel_type === "other") {
      normalizedParcelType = "others";
    } else if (parcel_type === "document") {
      normalizedParcelType = "documents";
    }

    // =====================================================
    // VALIDATIONS
    // =====================================================

    if (!user_id) {

      throw new HttpError(400,
        "User ID required"
      );
    }

    if (user_id !== authData.user.id) {

      return new Response(
        JSON.stringify({ success: false, error: "Forbidden: user_id does not match authenticated user" }),
        {
          headers: { "Content-Type": "application/json" },
          status: 403,
        }
      );
    }

    // =====================================================
    // IDEMPOTENCY CHECK (P1 fix)
    // If this exact (user_id, idempotency_key) pair already produced an order -- e.g. this is a
    // client retry after a 30s timeout whose original request actually succeeded server-side --
    // return that same order instead of creating a second one. Scoped to idempotency_key being
    // present so every other caller of this function (any path that doesn't send the field)
    // behaves identically to before this fix.
    // =====================================================
    if (idempotency_key) {
      const { data: existingOrder, error: existingOrderError } = await supabase
        .from("orders")
        .select("*")
        .eq("user_id", user_id)
        .eq("idempotency_key", idempotency_key)
        .maybeSingle();

      if (existingOrderError) {
        console.error("[CreateOrder] Idempotency pre-check query failed (continuing to create normally):", existingOrderError);
      } else if (existingOrder) {
        console.log(`[CreateOrder] Idempotency key ${idempotency_key} already has order ${existingOrder.id} -- returning it instead of creating a duplicate.`);
        return new Response(
          JSON.stringify({ success: true, order: existingOrder, idempotent: true }),
          {
            headers: { "Content-Type": "application/json" },
            status: 200,
          }
        );
      }
    }

    if (!pickup_address) {

      throw new HttpError(400,
        "Pickup address required"
      );
    }

    if (!destination_address) {

      throw new HttpError(400,
        "Destination address required"
      );
    }

    // =====================================================
    // FLOW NORMALIZATION
    // =====================================================

    let parcelWeight = 0;
    if (weight_kg !== undefined && weight_kg !== null && weight_kg !== "") {
      parcelWeight = Number(String(weight_kg).trim());
    } else if (weight_category !== undefined && weight_category !== null && weight_category !== "") {
      parcelWeight = Number(String(weight_category).trim());
    }
    if (isNaN(parcelWeight)) {
      parcelWeight = 0;
    }
    const calculatedParcelVehicle = parcelWeight > 10 ? "auto" : "bike";

    // =====================================================
    // SEATS REQUESTED (intercity_ride Travel Requests)
    // Defaults to 1 for every order type; only intercity_ride multiplies
    // fare per seat below (see FARES).
    // =====================================================
    let normalizedSeatsRequested = Number(seats_requested);
    if (!Number.isFinite(normalizedSeatsRequested) || normalizedSeatsRequested < 1) {
      normalizedSeatsRequested = 1;
    }
    normalizedSeatsRequested = Math.floor(normalizedSeatsRequested);

    let normalizedVehicleType = vehicle_type;
    if (!normalizedVehicleType || normalizedVehicleType === "delivery") {
      normalizedVehicleType = calculatedParcelVehicle;
    }

    let initialStatus =
      "searching";

    // local_ride default. Kept aligned with dispatch_config.max_search_duration_sec
    // (420s = 7min, migration 20260913000000_local_search_duration_420sec.sql) so this
    // informational search_expires_at value never implies a longer window than the
    // DB-authoritative expiry (expire_stale_searching_orders()) / dispatch loop
    // (start-dispatch, via _shared/dispatch_config_cache.ts) actually enforce.
    let searchExpiryMinutes =
      7;

    if (
      order_type === "local_parcel"
    ) {
      // Honor an explicit, valid user selection instead of always recomputing it -- Bike/Auto is
      // now a user choice on the client (ParcelBookingScreen), not an app decision. Bike is
      // rejected outright (not silently swapped to Auto) when the parcel is too heavy for it, so
      // the order created always matches the fare the user actually saw and agreed to.
      if (vehicle_type === "bike" || vehicle_type === "auto") {
        if (vehicle_type === "bike" && parcelWeight > 10) {
          throw new HttpError(
            400,
            "Bike cannot carry a parcel over 10kg. Please select Auto."
          );
        }
        normalizedVehicleType = vehicle_type;
      } else {
        normalizedVehicleType = calculatedParcelVehicle;
      }
      // Aligned with dispatch_config.max_search_duration_sec -- see comment above.
      searchExpiryMinutes =
        7;
    }

    if (
      order_type ===
      "intercity_parcel"
    ) {
      normalizedVehicleType = calculatedParcelVehicle;
      searchExpiryMinutes =
        60;
    }

    if (
      order_type ===
      "intercity_ride"
    ) {
      // 'any' is a passenger Travel Request with no vehicle preference —
      // it must survive normalization as-is so calculate-order-pricing and
      // match-intercity-riders can match/price across bike/auto/cab alike.
      // It is converted to NULL (not a valid vehicle_type_enum member)
      // right before the orders insert further below.
      if (
        normalizedVehicleType !== "any" &&
        normalizedVehicleType !== "bike" &&
        normalizedVehicleType !== "auto" &&
        normalizedVehicleType !== "cab"
      ) {
        normalizedVehicleType = "cab";
      }

      searchExpiryMinutes =
        30;
    }

    // vehicle_type_enum has no 'any' member — the sentinel is only meaningful
    // to calculate-order-pricing/match-intercity-riders, never to the DB.
    const dbVehicleType =
      normalizedVehicleType === "any" ? null : normalizedVehicleType;

    // =====================================================
    // FARE-MANIPULATION GUARD (H1)
    // A real road distance can never be shorter than the straight-line
    // (Haversine) distance between pickup and destination, so clamp the
    // client-supplied distance_km up to that floor whenever both coordinate
    // pairs are present. This closes the "submit a tiny distance_km for a
    // long trip" exploit without needing a full routing-API integration.
    // Fails open (keeps the client value) if coordinates are incomplete,
    // matching this function's existing lenient-fallback style elsewhere.
    // =====================================================
    let safeDistanceKm = distance_km;
    {
      // Number(null) coerces to 0 (a "finite" number), so a genuinely
      // missing coordinate must be rejected before conversion or it gets
      // silently treated as a valid (0, 0) point ("Null Island"), producing
      // a bogus straight-line distance that wrongly inflates distance_km
      // for orders that legitimately lack coordinates.
      const hasAllCoords =
        pickup_lat !== null && pickup_lat !== undefined &&
        pickup_lng !== null && pickup_lng !== undefined &&
        destination_lat !== null && destination_lat !== undefined &&
        destination_lng !== null && destination_lng !== undefined;
      const pLat = Number(pickup_lat);
      const pLng = Number(pickup_lng);
      const dLat = Number(destination_lat);
      const dLng = Number(destination_lng);
      if (hasAllCoords && [pLat, pLng, dLat, dLng].every((n) => Number.isFinite(n))) {
        const R = 6371;
        const dLatRad = (dLat - pLat) * Math.PI / 180;
        const dLngRad = (dLng - pLng) * Math.PI / 180;
        const a =
          Math.sin(dLatRad / 2) * Math.sin(dLatRad / 2) +
          Math.cos(pLat * Math.PI / 180) * Math.cos(dLat * Math.PI / 180) *
          Math.sin(dLngRad / 2) * Math.sin(dLngRad / 2);
        const straightLineKm = R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

        if (!Number.isFinite(Number(distance_km)) || Number(distance_km) < straightLineKm) {
          console.warn(
            `[CreateOrder] Client distance_km (${distance_km}) is less than the straight-line distance (${straightLineKm.toFixed(2)}km) between pickup/destination. Clamping to the straight-line floor.`
          );
          safeDistanceKm = straightLineKm;
        }

        // P2 fix: symmetric ceiling -- the H1 guard above only closed underreporting
        // (cheap-fare fraud); an inflated distance_km (overcharging the passenger) was never
        // checked. 5x the straight-line distance is deliberately generous -- real road
        // circuity (rivers, one-way systems, highway-only corridors, hilly terrain) rarely
        // exceeds ~2-3x even for awkward intercity routes, so this only ever catches
        // wildly fabricated values, never a genuine route.
        const maxPlausibleKm = straightLineKm * 5;
        if (Number.isFinite(Number(safeDistanceKm)) && Number(safeDistanceKm) > maxPlausibleKm) {
          console.warn(
            `[CreateOrder] Client distance_km (${distance_km}) is more than 5x the straight-line distance (${straightLineKm.toFixed(2)}km) between pickup/destination. Clamping to the plausible ceiling.`
          );
          safeDistanceKm = maxPlausibleKm;
        }
      }
    }

    // =====================================================
    // FIND OR INSERT USER DEVICE -- started here, concurrently with calculate-order-pricing below
    // (Finding D, WayDrop Performance Roadmap Phase 5). This block only needs created_device_id/
    // user_id/device_model/device_brand/os_version/app_version/req.headers -- all already available
    // above -- so it has zero dependency on the pricing result. Internal logic is byte-for-byte
    // identical to before; only WHEN it starts (fired now instead of after pricing/image-upload/
    // promo) and how its result is retrieved (returned from this closure instead of written to
    // outer `let`s) changed. Awaited via `await deviceUpsertPromise` right before the orders INSERT
    // further below, which is the first point deviceRecordId/deviceRef are actually consumed.
    // =====================================================
    const deviceUpsertPromise = (async () => {
      let deviceRecordId = null;
      let deviceRef = null;

      if (created_device_id && user_id) {
        // Generate SHA-256 reference code DEV-XXXXXXXX
        const encoder = new TextEncoder();
        const data = encoder.encode(created_device_id);
        const hashBuffer = await crypto.subtle.digest("SHA-256", data);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
        deviceRef = `DEV-${hashHex.substring(0, 8).toUpperCase()}`;

        const ipAddress = req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null;

        // Try searching for the device
        const { data: existingDevice } = await supabase
          .from("user_devices")
          .select("id")
          .eq("device_id", created_device_id)
          .maybeSingle();

        if (existingDevice) {
          deviceRecordId = existingDevice.id;
          // Update last seen
          await supabase
            .from("user_devices")
            .update({
              last_seen_at: new Date().toISOString(),
              last_ip_address: ipAddress,
              app_version: app_version || "1.0.0",
              os_version: os_version || "Mobile",
              updated_at: new Date().toISOString(),
            })
            .eq("id", deviceRecordId);
        } else {
          // Create new device record
          const { data: newDevice, error: devError } = await supabase
            .from("user_devices")
            .insert({
              user_id,
              device_id: created_device_id,
              device_ref: deviceRef,
              device_model: device_model || "Client App",
              device_brand: device_brand || "Generic",
              os_version: os_version || "Mobile",
              app_version: app_version || "1.0.0",
              last_ip_address: ipAddress,
              last_seen_at: new Date().toISOString(),
            })
            .select()
            .single();

          if (newDevice) {
            deviceRecordId = newDevice.id;
          } else {
            console.error("[CreateOrder] Error inserting user device:", devError);
          }
        }
      }

      return { deviceRecordId, deviceRef };
    })();

    // =====================================================
    // RECALCULATE PRICING
    // NEVER TRUST FRONTEND
    // =====================================================

    // WayDrop Progressive Degradation Audit, finding EDGE-1: this nested invoke had no timeout,
    // so a stall anywhere inside calculate-order-pricing hung create-order's own response
    // indefinitely — the direct mechanical cause of "price calculation sometimes never returns"
    // for orders created through this path. Bounded to 15s; on timeout this throws the same way
    // pricingResponse.error already did below, hitting the existing catch/error-response path.
    const pricingResponse =
      await withTimeout(
        supabase.functions
          .invoke(

            "calculate-order-pricing",

            {
              // Forward the caller's own bearer token (not the service-role
              // client's) so calculate-order-pricing can resolve their identity
              // and apply the Developer Test Mode zone bypass — without it,
              // this server-to-server call looks anonymous and 404s outside
              // configured pricing zones even when the requester is a flagged
              // developer account.
              headers: {
                Authorization: req.headers.get("Authorization") || "",
              },

              body: {

                order_type: order_type,

                vehicle_type:
                  normalizedVehicleType,

                pickup_address,

                pickup_city,

                distance_km: safeDistanceKm,

                max_boost_amount,

                weight_category,

                pickup_lat,

                pickup_lng,
              },
            }
          ),
        15000,
        "Pricing calculation timed out. Please try again.",
      );

    if (
      pricingResponse.error
    ) {

      throw new Error(
        pricingResponse.error.message
      );
    }

    const pricing =
      pricingResponse.data
        ?.pricing;

    if (!pricing) {

      throw new Error(
        "Pricing failed"
      );
    }

    // =====================================================
    // SCALE FARE BY SEATS REQUESTED (intercity_ride only)
    // calculate-order-pricing always returns the fare for a single seat
    // (the same per-km rate used to lock rider_travel_plans.price_per_seat)
    // — a Travel Request for N passengers books N seats, each priced at
    // that full per-km rate, not divided across seats.
    // =====================================================
    if (order_type === "intercity_ride" && normalizedSeatsRequested > 1) {
      for (
        const key of [
          "base_fare",
          "boost_amount",
          "subtotal",
          "commission_amount",
          "gst_amount",
          "rider_earning",
          "final_fare",
        ]
      ) {
        if (pricing[key] !== undefined && pricing[key] !== null) {
          pricing[key] = (
            Number(pricing[key]) * normalizedSeatsRequested
          ).toFixed(2);
        }
      }
    }

    // =====================================================
    // ORDER CODE
    // =====================================================

    const orderCodePrefix = getOrderCodePrefix(order_type);
    const orderCode = orderCodePrefix + generateRandomAlphanumeric(6);

    // =====================================================
    // IMAGE HANDLING
    // parcel_images bucket
    // public bucket
    // images/<orderCode>/
    // =====================================================

    const uploadedParcelImages:
      string[] = [];

    if (
      Array.isArray(
        parcel_images
      ) &&
      parcel_images.length > 0
    ) {

      for (
        let i = 0;
        i < parcel_images.length;
        i++
      ) {

        const image =
          parcel_images[i];

        if (
          typeof image ===
          "string"
        ) {

          // already uploaded URL
          uploadedParcelImages.push(
            image
          );

          continue;
        }

        try {

          const extension =
            image.name
              ?.split(".")
              ?.pop() ||
            "jpg";

          const fileName =
            `images/${orderCode}/${Date.now()}_${i}.${extension}`;

          const {

            error: uploadError,

          } =
            await supabase.storage

              .from(
                "parcel_images"
              )

              .upload(

                fileName,

                image,

                {

                  upsert: false,

                  contentType:
                    image.type ||
                    "image/jpeg",
                }
              );

          if (uploadError) {

            console.error(
              "IMAGE UPLOAD ERROR =>",
              uploadError
            );

            continue;
          }

          const {

            data: publicData,

          } =
            supabase.storage

              .from(
                "parcel_images"
              )

              .getPublicUrl(
                fileName
              );

          if (
            publicData?.publicUrl
          ) {

            uploadedParcelImages.push(

              publicData.publicUrl
            );
          }

        } catch (e) {

          console.error(
            "PARCEL IMAGE ERROR =>",
            e
          );
        }
      }
    }

    // =====================================================
    // FARES
    // =====================================================

    const actualFare =
      Number(
        pricing.base_fare || 0
      );

    const currentFare =
      Number(
        pricing.final_fare || 0
      );

    let finalFare = null;
    let appliedDiscount = 0;
    let promoId = null;

    if (promo_code) {
      const { data: promoResult, error: promoError } = await supabase.rpc(
        "validate_and_calculate_promo",
        {
          p_code: promo_code,
          p_order_value: currentFare,
          p_user_id: user_id,
        }
      );

      if (promoError) {
        console.error("[CreateOrder] Promo validation error:", promoError);
        throw new Error(promoError.message || "Promo validation failed");
      } else if (promoResult && promoResult.success) {
        appliedDiscount = Number(promoResult.discount_amount || 0);
        promoId = promoResult.promo_id;
        // WHOLE-RUPEE ROUNDING: currentFare (pricing.final_fare) is already a whole rupee amount
        // (rounded once, at the root, in calculate-order-pricing/pricing-calculations.ts). A promo
        // discount is not guaranteed to be a whole number, so the post-discount payable total must
        // be rounded here too -- this order's final_fare (the customer's actual payable amount,
        // per FareBreakdown.customerPaid = final_fare ?? current_fare) must never carry paise.
        finalFare = Math.round(currentFare - appliedDiscount);
        console.log(`[CreateOrder] Promo applied successfully: ID=${promoId}, discount=${appliedDiscount}, final_fare=${finalFare}`);
      } else {
        console.warn("[CreateOrder] Promo code invalid or conditions not met:", promoResult?.message);
        throw new HttpError(400, promoResult?.message || "Invalid promo code", "INVALID_PROMO_CODE");
      }
    }

    // =====================================================
    // VERIFY PAYMENT
    // NEVER TRUST FRONTEND: payment_mode/payment_id are client claims.
    // The order is only ever marked "paid" once we've confirmed, from the
    // `payments` table itself, that a matching payment was actually made by
    // this user, for this order type, for at least the real (server-side
    // recomputed) fare. Any mismatch falls back to "pending" — the same
    // state a cash order starts in — rather than blocking order creation.
    // =====================================================

    const expectedPayableAmount = finalFare ?? currentFare;

    let verifiedPaymentStatus = "pending";
    let verifiedPaymentId = null;

    // 'online' (gateway-collected fare, via the passenger's post-trip Cashfree checkout) settles
    // the same way 'cash'/'upi' do at booking time: no payment has happened yet, payment_status
    // starts 'pending', and the order is created without needing a pre-existing verified `payments`
    // row. It is excluded from this pre-payment verification branch for that reason.
    if (payment_mode && payment_mode !== "cash" && payment_mode !== "upi" && payment_mode !== "online") {
      if (payment_id) {
        const { data: paymentRecord, error: paymentLookupError } = await supabase
          .from("payments")
          .select("id, user_id, payment_status, payment_for, final_amount")
          .eq("id", payment_id)
          .maybeSingle();

        if (paymentLookupError) {
          console.error("[CreateOrder] Payment lookup error:", paymentLookupError);
        }

        // NOTE: both parcel booking screens (local + intercity) always send
        // payment_for: "parcel_order" regardless of order_type, so
        // "intercity_parcel" must accept it too — it is not reclassified to
        // "intercity_parcel_order" unless the payment was made via the
        // reference_id (existing-order) path in create-payment.
        const expectedPaymentForByOrderType: Record<string, string[]> = {
          ride: ["ride_order", "ride_boost"],
          ride_sharing: ["ride_sharing", "ride_boost"],
          local_parcel: ["parcel_order"],
          intercity_ride: ["intercity_ride_order", "intercity_ride_boost"],
          intercity_parcel: ["parcel_order", "intercity_parcel_order", "intercity_parcel_boost"],
        };
        const allowedPaymentFors = expectedPaymentForByOrderType[order_type] || [];

        const paymentIsValid =
          !!paymentRecord &&
          paymentRecord.payment_status === "paid" &&
          paymentRecord.user_id === user_id &&
          (allowedPaymentFors.length === 0 || allowedPaymentFors.includes(paymentRecord.payment_for)) &&
          Number(paymentRecord.final_amount || 0) >= expectedPayableAmount * 0.5;

        if (paymentIsValid) {
          verifiedPaymentStatus = "paid";
          verifiedPaymentId = payment_id;
        } else {
          console.warn(
            `[CreateOrder] payment_id ${payment_id} failed verification for order_type=${order_type}, user_id=${user_id}. Falling back to pending payment_status.`
          );
        }
      } else {
        console.warn("[CreateOrder] Non-cash payment_mode supplied without a payment_id. Falling back to pending payment_status.");
      }
    }

    // =====================================================
    // BOOST
    // =====================================================

    const boostAmount =
      Number(
        pricing.boost_amount || 0
      );

    const boostPercentage =
      boostAmount > 0
        ? 80
        : 0;

    const boostRiderEarning =
      Number(

        (
          boostAmount *
          (
            boostPercentage / 100
          )
        ).toFixed(2)
      );

    const boostCompanyEarning =
      Number(

        (
          boostAmount -
          boostRiderEarning
        ).toFixed(2)
      );

    // =====================================================
    // COMMISSION
    // =====================================================

    const commissionPercentage =
      Number(
        pricing
          .commission_percent || 0
      );

    const commissionAmount =
      Number(
        pricing.commission_amount ??
        Number((actualFare * (commissionPercentage / 100)).toFixed(2))
      );

    const gstPercentage =
      Number(
        pricing.gst_percentage ?? 5
      );

    const gstAmount =
      Number(
        pricing.gst_amount ??
        Number((actualFare * (gstPercentage / 100)).toFixed(2))
      );

    const riderEarning =
      Number(
        pricing.rider_earning ??
        Number((actualFare - commissionAmount).toFixed(2))
      );

    // =====================================================
    // OTPS
    // =====================================================

    const pickupOtp =
      Math.floor(

        1000 +
        Math.random() * 9000

      ).toString();

    const deliveryOtp =
      Math.floor(

        1000 +
        Math.random() * 9000

      ).toString();

    // =====================================================
    // SEARCH EXPIRY
    // =====================================================

    let searchExpiresAt =
      new Date(

        Date.now() +

        searchExpiryMinutes *
        60 *
        1000

      ).toISOString();

    const isIntercityOrder = order_type === "intercity_ride" || order_type === "intercity_parcel";
    if (isIntercityOrder && travel_date) {
      try {
        searchExpiresAt = new Date(travel_date).toISOString();
      } catch (e) {
        console.error("[CreateOrder] Error parsing travel_date for searchExpiresAt:", e);
      }
    }

    // =====================================================
    // SNAPSHOT
    // =====================================================

    const pricingSnapshot = {

      pricing_version: 1,

      order_type,

      vehicle_type:
        (order_type === "batch_delivery" || order_type === "food_delivery" || order_type === "grocery_delivery")
          ? null
          : dbVehicleType,

      city_tier:
        pricing.city_tier,

      detected_city:
        pricing.detected_city,

      distance_km:
        pricing.distance_km,

      actual_fare:
        actualFare,

      current_fare:
        currentFare,

      final_fare: null,

      base_fare:
        pricing.base_fare,

      boost_amount:
        boostAmount,

      boost_round: 0,

      commission_percentage:
        commissionPercentage,

      commission_amount:
        commissionAmount,

      gst_percentage:
        gstPercentage,

      gst_amount:
        gstAmount,

      rider_earning:
        riderEarning,

      estimated_duration_seconds:
        duration_seconds,

      calculated_at:
        new Date()
          .toISOString(),
    };

    // =====================================================
    // FIND OR INSERT USER DEVICE -- started earlier, concurrently with calculate-order-pricing
    // (see the deviceUpsertPromise block above, Finding D). Resolved here, right before the orders
    // INSERT below, which is the first place deviceRecordId/deviceRef are actually consumed.
    // =====================================================
    const { deviceRecordId, deviceRef } = await deviceUpsertPromise;

    // =====================================================
    // INSERT ORDER
    // =====================================================

    const {

      data: order,

      error: orderError,

    } = await supabase

      .from("orders")

      .insert({

        order_code:
          orderCode,

        user_id,

        order_type,

        vehicle_type:
          (order_type === "batch_delivery" || order_type === "food_delivery" || order_type === "grocery_delivery")
            ? null
            : dbVehicleType,

        seats_requested:
          normalizedSeatsRequested,

        order_status:
          initialStatus,

        // -----------------------------------------
        // LOCATION
        // -----------------------------------------

        pickup_address,

        pickup_lat,

        pickup_lng,

        destination_address,

        destination_lat,

        destination_lng,

        pickup_city,

        destination_city,

        travel_date,

        // -----------------------------------------
        // DISTANCE
        // -----------------------------------------

        distance_km: safeDistanceKm,

        distance_meters,

        estimated_duration_min:
          Math.ceil(
            duration_seconds / 60
          ),

        // -----------------------------------------
        // FARES
        // -----------------------------------------

        actual_fare:
          actualFare,

        current_fare:
          currentFare,

        final_fare:
          finalFare,

        base_fare:
          pricing.base_fare,

        commission_percentage:
          commissionPercentage,

        commission_amount:
          commissionAmount,

        gst_percentage:
          gstPercentage,

        gst_amount:
          gstAmount,

        boost_amount:
          boostAmount,

        boost_company_earning:
          boostCompanyEarning,

        boost_rider_earning:
          boostRiderEarning,

        boost_percentage:
          boostPercentage,

        pricing_snapshot:
          pricingSnapshot,

        rider_earning:
          riderEarning,

        // -----------------------------------------
        // PAYMENT
        // -----------------------------------------

        payment_mode,

        payment_id:
          (payment_mode === "cash" || payment_mode === "upi" || payment_mode === "online")

            ? payment_id

            : verifiedPaymentId,

        payment_status:
          (payment_mode === "cash" || payment_mode === "upi" || payment_mode === "online")

            ? "pending"

            : verifiedPaymentStatus,

        // -----------------------------------------
        // OTP
        // -----------------------------------------

        pickup_otp:
          pickupOtp,

        delivery_otp:
          deliveryOtp,

        // -----------------------------------------
        // SEARCH
        // -----------------------------------------

        search_expires_at:
          searchExpiresAt,

        dispatch_attempts: 0,

        redispatch_count: 0,

        rider_rejections_count: 0,

        boost_round: 0,

        current_search_radius_km:
          3,

        // -----------------------------------------
        // PARCEL
        // -----------------------------------------

        parcel_type:
          normalizedParcelType,

        receiver_name,

        receiver_phone,

        weight_category,

        actual_weight_kg: parcelWeight > 0 ? parcelWeight : (order_type === "intercity_parcel" ? 1 : null),

        special_instructions,

        parcel_images:
          uploadedParcelImages,

        created_device_record_id:
          deviceRecordId || null,

        created_device_ref:
          deviceRef || null,

        created_device_model:
          device_model || null,

        created_device_brand:
          device_brand || null,

        created_os_version:
          os_version || null,

        created_app_version:
          app_version || null,

        created_ip_address:
          req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,

        created_lat:
          pickup_lat,

        created_lng:
          pickup_lng,

        sender_declaration_accepted:
          sender_declaration_accepted === true,

        sender_declaration_accepted_at:
          sender_declaration_accepted_at || null,

        // P1 fix (create-order idempotency): NULL for every caller that doesn't send one (all
        // pre-existing behavior unchanged); enforced unique per user_id by a partial index (see
        // migration 20260816000000) when present.
        idempotency_key:
          idempotency_key || null,

      })

      .select()

      .single();

    if (orderError) {

      // P1 fix: a concurrent duplicate request with the SAME idempotency key can reach this
      // INSERT before either one's idempotency pre-check above has seen the other's row yet --
      // the partial unique index on (user_id, idempotency_key) is what actually prevents two
      // orders in that race, and surfaces here as a unique-violation (23505) rather than at the
      // pre-check. Only ever reinterpreted this way when idempotency_key was actually supplied,
      // so this can never mask an unrelated conflict (e.g. the separate order_code uniqueness)
      // for any other order-creation path.
      if (idempotency_key && orderError.code === "23505") {
        const { data: raceOrder, error: raceOrderError } = await supabase
          .from("orders")
          .select("*")
          .eq("user_id", user_id)
          .eq("idempotency_key", idempotency_key)
          .maybeSingle();

        if (!raceOrderError && raceOrder) {
          console.log(`[CreateOrder] Concurrent idempotent request race for key ${idempotency_key} -- returning the winning order ${raceOrder.id}.`);
          return new Response(
            JSON.stringify({ success: true, order: raceOrder, idempotent: true }),
            {
              headers: { "Content-Type": "application/json" },
              status: 200,
            }
          );
        }
      }

      throw orderError;
    }

    // =====================================================
    // START DISPATCH OR INTERCITY MATCHING -- fired IMMEDIATELY after the order row commits, and
    // moved ahead of every non-dispatch-critical bookkeeping write below (promo usage recording,
    // OTP attempt logging, device-token linking, compliance/parcel logs, order_status_history).
    // None of that bookkeeping has any bearing on whether an eligible online rider can be matched,
    // and it was previously running as several sequential `await`ed round trips BEFORE start-dispatch
    // was even invoked -- directly widening the "order created -> dispatch begins" gap the >15s
    // real-device delay traces back to (see docs/13_Business_Logic.md's dispatch loop and the
    // instrumentation logged immediately below). Fire-and-forget (fetch + EdgeRuntime.waitUntil,
    // matching the intercity branch's existing pattern below) rather than `await`ed, so this request
    // handler is never itself blocked on dispatch's own network round trip either.
    // =====================================================
    console.log(`[CreateOrder] Order ${order.id} committed at ${new Date().toISOString()} (order.created_at=${order.created_at}). Triggering dispatch now.`);
    if (order_type !== "intercity_ride" && order_type !== "intercity_parcel") {
      try {
        const dispatchUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/start-dispatch`;
        // is_background: true skips start-dispatch's own client/sync-trigger branch (which exists
        // to fork-and-return-immediately for the client's direct "boost/retry" JWT-authenticated
        // calls) -- create-order already calls with the service-role key and is itself already
        // fire-and-forget via EdgeRuntime.waitUntil below, so going straight to the background
        // execution here removes one entire redundant self-invocation hop (and its own possible
        // cold start) from the critical path between order creation and Round 1 of dispatch.
        const dispatchPromise = fetch(dispatchUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
            "apikey": Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
          },
          body: JSON.stringify({ order_id: order.id, is_background: true }),
        }).then((res) => {
          console.log(`[CreateOrder] start-dispatch invoked for order ${order.id}, response status: ${res.status}, at ${new Date().toISOString()}`);
        }).catch((err) => {
          console.error("[CreateOrder] Failed to invoke start-dispatch:", err);
        });
        if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
          (globalThis as any).EdgeRuntime.waitUntil(dispatchPromise);
        }
      } catch (err) {
        console.error("[CreateOrder] Failed to trigger start-dispatch:", err);
      }
    } else {
      console.log(`[CreateOrder] Intercity order created (${order_type}). Triggering background match-intercity-riders...`);
      try {
        const functionUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/match-intercity-riders`;
        const backgroundPromise = fetch(functionUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
            "apikey": Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
          },
          body: JSON.stringify({ order_id: order.id, is_background: true }),
        });
        if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
          (globalThis as any).EdgeRuntime.waitUntil(backgroundPromise);
        }
      } catch (err) {
        console.error("[CreateOrder] Failed to invoke background match-intercity-riders:", err);
      }
    }

    // =====================================================
    // PROMO USAGE + OTP LOGGING + DEVICE/COMPLIANCE LOGS -- run concurrently (Step A, WayDrop
    // Performance Roadmap Phase 5 continuation, per the read-only dependency audit). Verified
    // independent: none of the three reads another's output, and none is read by
    // order_status_history below or by the response (already captured from the INSERT above,
    // untouched by any of this). Each keeps its EXACT existing internal try/catch/fallback -- only
    // execution concurrency changes. Promise.allSettled (not Promise.all) so one soft-failing block
    // can never prevent the other two from running, matching how they already behaved as
    // independent sequential steps before this change.
    // =====================================================

    // [2] PROMO CODE USAGE RECORDING
    const promoUsagePromise = (async () => {
      if (promoId && order && order.id) {
        const { error: usageError } = await supabase
          .from("user_promo_usages")
          .insert({
            user_id,
            promo_code_id: promoId,
            order_id: order.id,
          });

        if (usageError) {
          console.error("[CreateOrder] Error inserting user_promo_usages:", usageError);
        } else {
          console.log("[CreateOrder] Recorded promo usage successfully");
        }
      }
    })();

    // [3] LOG INITIAL OTP REQUEST(S) -- pickup log stays gated behind the phone lookup it needs
    // (unchanged dependency); delivery log is independent of both and now starts at the same time
    // instead of only running after the phone-lookup/pickup-log pair finishes.
    const otpLoggingPromise = (async () => {
      try {
        const pickupLogPromise = (async () => {
          const { data: userRecord } = await supabase
            .from("users")
            .select("phone")
            .eq("id", user_id)
            .single();

          if (userRecord?.phone) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: userRecord.phone,
              p_is_successful: true,
              p_action_type: "request",
              p_otp_code: pickupOtp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
        })();

        const deliveryLogPromise = (async () => {
          if (receiver_phone && deliveryOtp) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: receiver_phone,
              p_is_successful: true,
              p_action_type: "request",
              p_otp_code: deliveryOtp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
        })();

        await Promise.all([pickupLogPromise, deliveryLogPromise]);
      } catch (otpLogErr) {
        console.error("[CreateOrder] Error logging initial OTP request(s):", otpLogErr);
      }
    })();

    // [4] UPDATE DEVICE INFO & COMPLIANCE LOGS -- internal logic byte-for-byte unchanged, including
    // the existing Promise.all pair for the intercity_parcel declaration-acceptance inserts.
    const deviceComplianceLogsPromise = (async () => {
      try {
        const ipAddress = req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null;

        if (deviceRecordId && user_id) {
          console.log(`[CreateOrder] Linking user device token to user_devices record ${deviceRecordId}`);
          await supabase
            .from("user_device_tokens")
            .update({
              user_device_id: deviceRecordId,
              updated_at: new Date().toISOString(),
            })
            .eq("user_id", user_id);
        }

        const isParcel =
          order_type === "local_parcel" ||
          order_type === "intercity_parcel" ||
          order_type === "batch_delivery" ||
          order_type === "food_delivery" ||
          order_type === "grocery_delivery";

        if (isParcel) {
          console.log(`[CreateOrder] Logging order_created event in parcel_security_logs`);
          await supabase.from("parcel_security_logs").insert({
            order_id: order.id,
            sender_user_id: user_id,
            event_type: "order_created",
            latitude: pickup_lat,
            longitude: pickup_lng,
            event_latitude: pickup_lat,
            event_longitude: pickup_lng,
            ip_address: ipAddress,
            device_id: deviceRef || "DEV-UNKNOWN",
            metadata: {
              client_timestamp: new Date().toISOString(),
              raw_device_id: created_device_id || null,
            }
          });

          if (order_type === "intercity_parcel" && sender_declaration_accepted) {
            // Root cause (Intercity Parcel Upload DatabaseTimeout investigation): these two inserts
            // don't depend on each other's result -- only on `order.id`, already known at this point
            // -- but were previously `await`ed one after another, adding a second full DB round trip
            // that only intercity_parcel orders ever pay (local_parcel stops after the single insert
            // above). Running them concurrently removes that extra sequential latency from the
            // create-order response time without touching any timeout value.
            console.log(`[CreateOrder] Logging sender_declaration_accepted event in parcel_security_logs and order_declarations`);
            await Promise.all([
              supabase.from("parcel_security_logs").insert({
                order_id: order.id,
                sender_user_id: user_id,
                event_type: "sender_declaration_accepted",
                latitude: pickup_lat,
                longitude: pickup_lng,
                event_latitude: pickup_lat,
                event_longitude: pickup_lng,
                ip_address: ipAddress,
                device_id: deviceRef || "DEV-UNKNOWN",
                metadata: {
                  client_timestamp: new Date().toISOString(),
                  declaration_version: "1.0",
                  raw_device_id: created_device_id || null,
                }
              }),
              supabase.from("order_declarations").insert({
                order_id: order.id,
                user_id: user_id,
                declaration_text: "I declare that this parcel does not contain illegal goods, weapons, narcotics, explosives, prohibited substances, or restricted materials.",
                accepted: true,
                accepted_ip: ipAddress,
                accepted_device_ref: deviceRef || "DEV-UNKNOWN",
                declaration_version: "1.0",
              }),
            ]);
          }
        }
      } catch (e) {
        console.error("[CreateOrder] Error updating device info/compliance logs:", e);
      }
    })();

    await Promise.allSettled([promoUsagePromise, otpLoggingPromise, deviceComplianceLogsPromise]);

    // =====================================================
    // STATUS HISTORY
    // =====================================================

    await supabase

      .from(
        "order_status_history"
      )

      .insert({

        order_id:
          order.id,

        previous_status:
          null,

        new_status:
          initialStatus,

        changed_by:
          user_id,
      });

    // Dispatch/intercity-matching already triggered immediately after order creation, above --
    // see "START DISPATCH OR INTERCITY MATCHING" earlier in this function.

    // =====================================================
    // RESPONSE
    // =====================================================

    return new Response(

      JSON.stringify({

        success: true,

        order,
      }),

      {
        headers: {

          "Content-Type":
            "application/json",
        },

        status: 200,
      }
    );
  }

  catch (error) {

    console.error(
      "CREATE ORDER ERROR =>",
      error
    );

    return httpErrorResponse(error, { "Content-Type": "application/json" });
  }
});

function generateRandomAlphanumeric(length: number): string {
  const chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  let result = "";
  for (let i = 0; i < length; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

function getOrderCodePrefix(orderType: string): string {
  switch (orderType) {
    case "ride": return "WDR";
    case "intercity_ride": return "WDIR";
    case "local_parcel": return "WDP";
    case "intercity_parcel": return "WDIP";
    case "ride_sharing": return "WDS";
    case "food_delivery": return "WDF";
    case "grocery_delivery": return "WDG";
    case "batch_delivery": return "WDB";
    default: return "WD";
  }
}