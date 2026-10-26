import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { fetchWithTimeout } from "../_shared/http.ts";
import { getDispatchConfig } from "../_shared/dispatch_config_cache.ts";
import {
  DispatchRoundStatusError,
  dispatchRoundStatusFailureResponse,
  readDispatchRoundStatus,
} from "../_shared/dispatch_round_status.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

class DispatchLockCleanupError extends Error {
  constructor() {
    super("Dispatch lock cleanup unavailable");
    this.name = "DispatchLockCleanupError";
  }
}

// Validate the selected history projection without normalizing database values.
function isValidAssignmentHistoryRow(value: unknown): boolean {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  const nullableTimestamp = (field: unknown) => field === null ||
    (typeof field === "string" && Number.isFinite(Date.parse(field)));
  const nullableNumeric = (field: unknown) => field === null ||
    (typeof field === "number" && Number.isFinite(field)) ||
    (typeof field === "string" &&
      /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(field) &&
      Number.isFinite(Number(field)));
  return typeof row.rider_id === "string" && row.rider_id.trim().length > 0 &&
    typeof row.assignment_status === "string" &&
    ["sent", "viewed", "accepted", "rejected", "timed_out", "expired", "cancelled", "accepted_by_user"]
      .includes(row.assignment_status) &&
    nullableTimestamp(row.responded_at) && nullableTimestamp(row.hidden_until) &&
    nullableNumeric(row.last_seen_fare) && nullableNumeric(row.estimated_earnings);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  try {
    // =====================================================
    // SUPABASE
    // =====================================================
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // =====================================================
    // BODY
    // =====================================================
    const body = await req.json();
    const order_id = body.order_id;

    if (!order_id) {
      return new Response(
        JSON.stringify({
          success: false,
          message: "order_id required",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // =====================================================
    // AUTH
    // Accepts either the service-role key (internal server-to-server
    // chaining/background triggers) or a valid end-user JWT (client-side
    // "boost"/retry search calls).
    // =====================================================
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!token) {
      return new Response(
        JSON.stringify({ success: false, message: "Missing auth token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const isServiceRoleCaller = token === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!isServiceRoleCaller) {
      const { data: authData, error: authError } = await supabase.auth.getUser(token);
      if (authError || !authData.user) {
        return new Response(
          JSON.stringify({ success: false, message: "Unauthorized" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // OWNERSHIP CHECK (P2 fix): a non-service-role caller (client-side "boost"/retry
      // search calls) could previously trigger a dispatch pass for ANY order_id, not just
      // their own -- low-impact (this only forces a harmless, idempotent rider-matching
      // pass, never returns/mutates sensitive data to the caller), but still a real
      // resource-abuse gap with no legitimate use. Only the order's own passenger or its
      // currently assigned rider may trigger it.
      const { data: ownedOrder } = await supabase
        .from("orders")
        .select("id, user_id, rider_id")
        .eq("id", order_id)
        .maybeSingle();

      if (!ownedOrder) {
        return new Response(
          JSON.stringify({ success: false, message: "Order not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const isPassenger = ownedOrder.user_id === authData.user.id;
      let isAssignedRider = false;
      if (!isPassenger && ownedOrder.rider_id) {
        const { data: ownRider } = await supabase
          .from("riders")
          .select("id")
          .eq("id", ownedOrder.rider_id)
          .eq("user_id", authData.user.id)
          .maybeSingle();
        isAssignedRider = ownRider != null;
      }

      if (!isPassenger && !isAssignedRider) {
        return new Response(
          JSON.stringify({ success: false, message: "Forbidden: not a participant on this order" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    const is_background = body.is_background === true;

    if (!is_background) {
      console.log(`[Dispatch] Client/Sync trigger for order ${order_id}. Forking background execution...`);
      const functionUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/start-dispatch`;
      // Bounded (10s) instead of a bare fetch() -- this is fire-and-forget (we never await the
      // response for anything), but an unbounded fetch left waiting under EdgeRuntime.waitUntil
      // can hold this isolate open indefinitely if the network stalls. Aborting after 10s doesn't
      // cancel the target invocation once it's been dispatched; it only stops us from waiting on
      // it. The 15s redispatch cron backstop (redispatch_stalled_searching_orders) already covers
      // the case where this call never lands at all.
      const backgroundPromise = fetchWithTimeout(functionUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
          "apikey": Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        },
        body: JSON.stringify({ order_id, is_background: true }),
      }, 10000).then(async (res) => {
        console.log("[Dispatch] Forked background execution started, status:", res.status);
      }).catch((err) => {
        console.error("[Dispatch] Forked background execution failed to start:", err);
      });

      if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
        (globalThis as any).EdgeRuntime.waitUntil(backgroundPromise);
      }

      return new Response(
        JSON.stringify({
          success: true,
          message: "Dispatch matching process started in the background",
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // =====================================================
    // FETCH ORDER
    // =====================================================
    // Column projection (WayDrop Performance Roadmap, backend hot-path pass): this row is never
    // returned in any response from this function (every response here is {success, message}
    // only, confirmed by reading every `return new Response(...)` in this file) -- it's used
    // purely internally, by this function's own dispatch-loop logic. Verified via a full trace of
    // every `order.`/`currentOrder.` access in this file: order_status, order_type, created_at,
    // dispatch_state, pickup_lat, pickup_lng, rider_earning, vehicle_type, actual_weight_kg,
    // weight_category. Same list applies to the iteration>1 refetch below (assigned to the same
    // `currentOrder` variable and used identically).
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("order_status,order_type,created_at,dispatch_state,pickup_lat,pickup_lng,rider_earning,vehicle_type,actual_weight_kg,weight_category")
      .eq("id", order_id)
      .single();

    if (orderError || !order) {
      console.error("ORDER FETCH ERROR:", orderError);
      return new Response(
        JSON.stringify({
          success: false,
          message: "Order not found",
        }),
        {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // Instrumentation: end-to-end trace point for the "order created -> dispatch begins" gap
    // (>15s real-device delay investigation). order.created_at is set at INSERT time by
    // create-order; comparing it against this timestamp measures exactly how long it took this
    // background dispatch worker to actually start running after the order was committed --
    // covering the create-order->fetch/dispatch invocation, any cold start, and this order fetch.
    console.log(`[Dispatch] Background worker running for order ${order_id} at ${new Date().toISOString()} (order.created_at=${order.created_at}, gap_ms=${Date.now() - new Date(order.created_at).getTime()}).`);

    if (order.order_type === "intercity_ride" || order.order_type === "intercity_parcel") {
      console.log(`[Dispatch] Order ${order_id} is an intercity order (${order.order_type}). Skipping dispatch loop.`);
      return new Response(
        JSON.stringify({
          success: true,
          message: "Intercity order skipped in dispatch loop",
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // =====================================================
    // CONFIG
    // =====================================================
    // Cached (Performance Roadmap P0 #2) -- see _shared/dispatch_config_cache.ts. Same row shape,
    // same fields, just not a fresh query on every invocation of this function.
    const config = await getDispatchConfig(supabase);

    if (!config) {
      return new Response(
        JSON.stringify({
          success: false,
          message: "Dispatch config missing",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // Determine safe response timeout (seconds per round)
    let timeoutSec = Number(config.rider_response_timeout_sec) || 30;
    if (timeoutSec <= 0) {
      timeoutSec = 30;
    }

    // =====================================================
    // LOCK ACQUISITION (Distributed Lock Protection)
    // =====================================================
    const nowStr = new Date().toISOString();

    // Check if there is a stale lock (running for more than 120s)
    const { data: currentLockOrder } = await supabase
      .from("orders")
      .select("dispatch_worker_running, dispatch_worker_started_at")
      .eq("id", order_id)
      .single();

    let forceAcquire = false;
    let staleStartedAt: string | null = null;
    if (currentLockOrder && currentLockOrder.dispatch_worker_running) {
      const startedAt = currentLockOrder.dispatch_worker_started_at;
      if (startedAt) {
        const lockAgeMs = Date.now() - new Date(startedAt).getTime();
        if (lockAgeMs > 120 * 1000) {
          console.log(`[Dispatch] Found stale lock (age: ${(lockAgeMs / 1000).toFixed(1)}s). Forcing lock override.`);
          forceAcquire = true;
          staleStartedAt = startedAt;
        }
      }
    }

    let query = supabase
      .from("orders")
      .update({
        dispatch_worker_running: true,
        dispatch_worker_started_at: nowStr
      })
      .eq("id", order_id);

    if (!forceAcquire) {
      query = query.or("dispatch_worker_running.eq.false,dispatch_worker_running.is.null");
    } else {
      // Compare-and-swap on the exact stale timestamp just read (Prevent duplicate dispatch
      // workers, hardened): if two callers (e.g. the redispatch cron and a client retry) both see
      // the same stale lock at once, only the UPDATE that still matches this exact
      // dispatch_worker_started_at can win -- the loser's WHERE no longer matches once the winner
      // commits, so it correctly falls through to the "already running" exit below instead of
      // also starting a second worker for this order.
      query = query.eq("dispatch_worker_started_at", staleStartedAt);
    }

    const { data: lockAcquired, error: lockError } = await query.select("id").maybeSingle();

    if (lockError || !lockAcquired) {
      console.log(`[Dispatch] Could not acquire lock for order ${order_id}. Another worker is already running. Exiting.`);
      return new Response(
        JSON.stringify({
          success: false,
          message: "Another dispatch worker is already running for this order",
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    let chainedTriggered = false;
    let dispatchFailed = false;

    try {
      // =====================================================
      // RETRY MATCHING LOOP WITH AUTO-CHAINING & RADIUS SCALING
      // =====================================================
      const executionStartTime = Date.now();
      const safeTimeoutMs = 100 * 1000; // 100s safe execution cap for single Deno edge function run
      const maxSearchDurationMs = Number(config.max_search_duration_sec) * 1000;

      let iteration = 0;

      // Run loop while there is at least 15 seconds remaining to process a full round safely
      while (Date.now() - executionStartTime < safeTimeoutMs - 15000) {
        iteration++;
        console.log(`[Dispatch] Starting Loop Iteration ${iteration} for Order ${order_id} at ${new Date().toISOString()}`);

        // 1. Order details -- iteration 1 reuses the order already fetched immediately above
        // (microseconds old at this point) instead of re-fetching it, removing one avoidable DB
        // round trip from the hot path to Round 1. Iteration 2+ still re-fetches fresh, since real
        // time has passed (round timeouts/sleeps) and order_status/dispatch_state may have changed.
        let currentOrder = order;
        if (iteration > 1) {
          // Column projection: same internal-only field list as the initial fetch above --
          // refetchedOrder feeds the identical currentOrder = refetchedOrder assignment and is
          // used exactly the same way for the rest of this iteration.
          const { data: refetchedOrder, error: fetchErr } = await supabase
            .from("orders")
            .select("order_status,order_type,created_at,dispatch_state,pickup_lat,pickup_lng,rider_earning,vehicle_type,actual_weight_kg,weight_category")
            .eq("id", order_id)
            .single();

          if (fetchErr || !refetchedOrder) {
            console.error("[Dispatch] Error fetching order:", fetchErr);
            break;
          }
          currentOrder = refetchedOrder;
        }

        // Stop if order is no longer searching (e.g. accepted, cancelled, expired)
        if (currentOrder.order_status !== "searching") {
          console.log(`[Dispatch] Order status is "${currentOrder.order_status}". Stopping dispatch loop.`);
          return new Response(
            JSON.stringify({
              success: true,
              message: `Order status is ${currentOrder.order_status}, stopped dispatch loop`,
            }),
            {
              status: 200,
              headers: { ...corsHeaders, "Content-Type": "application/json" },
            },
          );
        }

        // Check overall search age (from creation time)
        const searchAgeSeconds = (Date.now() - new Date(currentOrder.created_at).getTime()) / 1000;
        if (searchAgeSeconds * 1000 > maxSearchDurationMs) {
          // ROOT CAUSE FIX ("old ride requests reaching online riders" / progressive dispatch-load
          // growth): this used to stop the loop WITHOUT changing order_status, leaving the order in
          // 'searching' indefinitely -- a live candidate for assign_nearby_searching_orders_to_rider()
          // (re-offered to any rider who later goes online) for as long as the passenger never
          // manually cancelled it. expire_stale_searching_orders()
          // (20260806000004_add_expire_stale_searching_orders_and_schedule.sql) is the same
          // idempotent, SET-based function a 1-minute pg_cron safety net also calls; invoking it here
          // makes THIS order's own give-up moment expire it immediately instead of waiting up to a
          // minute for that backstop, while still being exactly one already-tested code path -- not
          // duplicated logic. A failure here is logged, not thrown: the cron backstop still owns
          // eventual correctness if this call itself fails.
          console.log(`[Dispatch] Order ${order_id} search exceeded ${maxSearchDurationMs / 1000}s. Expiring order.`);
          const { error: expireError } = await supabase.rpc("expire_stale_searching_orders");
          if (expireError) {
            console.error("[Dispatch] expire_stale_searching_orders RPC failed (cron backstop will still catch this order):", expireError);
          }
          return new Response(
            JSON.stringify({
              success: true,
              message: "Overall search timeout reached, order expired",
            }),
            {
              status: 200,
              headers: { ...corsHeaders, "Content-Type": "application/json" },
            },
          );
        }

        // Calculate no rider duration if round1_no_rider_since is set
        const dispatchState = currentOrder.dispatch_state || {};
        let noRiderDuration = 0;
        if (dispatchState.round1_no_rider_since) {
          noRiderDuration = (Date.now() - new Date(dispatchState.round1_no_rider_since).getTime()) / 1000;
        }

        const rounds = [];

        // Round 1 always
        rounds.push({
          round: 1,
          radius: config.round_1_radius_km,
          limit: config.round_1_batch_size,
        });

        // Round 2
        const round2TriggerAfterSec = Number(config.round_2_trigger_after_sec);
        const round2NoRidersTriggerSec = Number(config.round_2_no_riders_trigger_sec ?? config.round_2_trigger_if_no_riders_sec);

        const triggerRound2 = (searchAgeSeconds >= round2TriggerAfterSec) ||
                              (dispatchState.round1_no_rider_since && noRiderDuration >= round2NoRidersTriggerSec);

        if (triggerRound2) {
          rounds.push({
            round: 2,
            radius: config.round_2_radius_km,
            limit: config.round_2_batch_size,
          });
        }

        // Round 3
        const round3TriggerAfterSec = Number(config.round_3_trigger_after_sec);
        if (config.allow_round_3 && searchAgeSeconds >= round3TriggerAfterSec) {
          rounds.push({
            round: 3,
            radius: config.round_3_radius_km,
            limit: config.round_3_batch_size,
          });
        }

        console.log(`[Dispatch] Order: ${order_id} | Search Age: ${searchAgeSeconds.toFixed(1)}s | No Rider Duration: ${noRiderDuration.toFixed(1)}s | Active Rounds: ${rounds.map(r => r.round).join(", ")}`);

        let anyAssignmentsSent = false;

        for (const roundConfig of rounds) {
          // Check if we are approaching Deno safe execution time cap
          if (Date.now() - executionStartTime > safeTimeoutMs - 15000) {
            console.log("[Dispatch] Near Deno safe execution cap. Breaking rounds loop to re-trigger.");
            break;
          }

          console.log(`[Dispatch] Iteration ${iteration} | Round ${roundConfig.round} (radius: ${roundConfig.radius.toFixed(2)}km)`);

          // Re-verify order is still searching before making database inserts/assignments.
          // Skipped for the FIRST round of this iteration only (Reduce unnecessary database
          // queries): currentOrder was fetched/reused immediately above with zero `await` in
          // between (the only intervening branch that awaits anything -- the max-search-duration
          // check -- returns early, so we can only reach here if it didn't run), so it is already
          // guaranteed fresh and already confirmed "searching" by that same check. Querying again
          // here would return the identical value. Round 2/3 still re-check for real, since real
          // time (round 1's send + poll loop) has elapsed by then.
          if (roundConfig !== rounds[0]) {
            const { data: checkOrder } = await supabase
              .from("orders")
              .select("order_status")
              .eq("id", order_id)
              .single();

            if (!checkOrder || checkOrder.order_status !== "searching") {
              console.log(`[Dispatch] Order status is ${checkOrder?.order_status || "unknown"}. Stopping round loop.`);
              return new Response(
                JSON.stringify({
                  success: true,
                  message: `Order status is ${checkOrder?.order_status || "unknown"}, stopped dispatch loop`,
                }),
                {
                  status: 200,
                  headers: { ...corsHeaders, "Content-Type": "application/json" },
                },
              );
            }
          }

          // Fetch existing assignments for this order FIRST (moved ahead of find_nearby_riders so
          // the already-known-excluded rider IDs can be passed into the RPC and skipped before it
          // does eligibility/KYC/tax/COD/active-trip/Haversine work for them). Exclusion RULES are
          // byte-for-byte unchanged from before this reordering -- only the read's position moved.
          const { data: existingAssignments, error: assignmentReadError } = await supabase
            .from("rider_assignments")
            .select("rider_id, assignment_status, responded_at, hidden_until, last_seen_fare, estimated_earnings")
            .eq("order_id", order_id);

          if (assignmentReadError) {
            console.error("[Dispatch] assignment history category=request_error");
            throw new Error("Dispatch assignment history unavailable");
          }
          if (!Array.isArray(existingAssignments) ||
              !existingAssignments.every(isValidAssignmentHistoryRow)) {
            console.error("[Dispatch] assignment history category=invalid_response");
            throw new Error("Dispatch assignment history unavailable");
          }

          const excludedRiderIds = new Set<string>();
          const nowMs = Date.now();

          for (const assignment of existingAssignments) {
            switch (assignment.assignment_status) {
              case "sent":
              case "accepted":
                excludedRiderIds.add(assignment.rider_id);
                break;

              case "rejected": {
                const hiddenUntil = assignment.hidden_until
                  ? new Date(assignment.hidden_until).getTime()
                  : null;
                if (hiddenUntil && nowMs < hiddenUntil) {
                  excludedRiderIds.add(assignment.rider_id);
                } else {
                  // After 4 minutes: show only if fare is boosted
                  const lastSeenFare = Number(assignment.last_seen_fare) || Number(assignment.estimated_earnings) || 0;
                  if (currentOrder.rider_earning <= lastSeenFare) {
                    excludedRiderIds.add(assignment.rider_id);
                  }
                }
                break;
              }

              case "expired": {
                // Ignored: Show again only if fare is boosted
                const lastSeenFare = Number(assignment.last_seen_fare) || Number(assignment.estimated_earnings) || 0;
                if (currentOrder.rider_earning <= lastSeenFare) {
                  excludedRiderIds.add(assignment.rider_id);
                }
                break;
              }
            }
          }

          // Fetch nearby online riders (this handles rides, parcels, KYC approvals, etc.). Already
          // known-excluded rider IDs are passed so find_nearby_riders can skip them before doing any
          // eligibility/KYC/tax/COD/active-trip/Haversine work.
          const findNearbyStart = Date.now();
          const { data: nearbyRiders, error: nearbyError } = await supabase.rpc(
            "find_nearby_riders",
            {
              p_order_id: order_id,
              p_pickup_lat: currentOrder.pickup_lat,
              p_pickup_lng: currentOrder.pickup_lng,
              p_radius_km: roundConfig.radius,
              p_limit: roundConfig.limit,
              p_excluded_rider_ids: Array.from(excludedRiderIds),
            },
          );
          console.log(`[Dispatch] find_nearby_riders (round ${roundConfig.round}) took ${Date.now() - findNearbyStart}ms, returned ${nearbyRiders?.length ?? 0} riders. Order age at this point: ${((Date.now() - new Date(currentOrder.created_at).getTime()) / 1000).toFixed(1)}s.`);

          if (nearbyError) {
            console.error(`[Dispatch] RPC Error in Round ${roundConfig.round}:`, nearbyError);
            continue;
          }

          // Special No-Rider Escalation tracking for Round 1
          if (roundConfig.round === 1) {
            const stateUpdate: any = { ...dispatchState };
            let changed = false;

            if (!nearbyRiders || nearbyRiders.length === 0) {
              console.log(`[Dispatch] No nearby riders in Round 1.`);
              if (!stateUpdate.round1_no_rider_since) {
                stateUpdate.round1_no_rider_since = new Date().toISOString();
                changed = true;
              }
            } else {
              if (stateUpdate.round1_no_rider_since) {
                delete stateUpdate.round1_no_rider_since;
                changed = true;
              }
            }

            if (changed) {
              console.log(`[Dispatch] Updating order dispatch_state to:`, JSON.stringify(stateUpdate));
              const { error: stateError } = await supabase
                .from("orders")
                .update({ dispatch_state: stateUpdate })
                .eq("id", order_id);
              if (stateError) {
                console.error("[Dispatch] Error updating order dispatch_state:", stateError);
              } else {
                currentOrder.dispatch_state = stateUpdate;
              }
            }
          }

          if (!nearbyRiders || nearbyRiders.length === 0) {
            console.log(`[Dispatch] No nearby riders in Round ${roundConfig.round}.`);
            continue;
          }

          // Defensive safety check: find_nearby_riders already excludes these rider IDs in SQL now,
          // but this JS-side re-check is kept as a defense-in-depth guard (e.g. in case a future
          // caller of this RPC path omits p_excluded_rider_ids, or the row was appended to
          // rider_assignments after existingAssignments was read above).
          const filteredRiders = nearbyRiders.filter(
            (rider: any) => {
              // 1. Exclude if rider is in the excluded list (expired/rejected/etc.)
              if (excludedRiderIds.has(rider.rider_id)) {
                return false;
              }

              const riderVehicle = (rider.vehicle_type || "").toLowerCase().trim();
              const orderType = (currentOrder.order_type || "").toLowerCase().trim();
              const reqVehicle = (currentOrder.vehicle_type || "").toLowerCase().trim();

              // 2. Ride Sharing vehicle check
              if (orderType === "ride_sharing") {
                return riderVehicle === "auto" || riderVehicle === "cab";
              }

              // 3. Passenger Ride vehicle check
              if (orderType === "ride" || orderType === "intercity_ride" || orderType === "intercity") {
                return riderVehicle === reqVehicle;
              }

              const isParcel = orderType === "local_parcel" ||
                               orderType === "intercity_parcel" ||
                               orderType.includes("parcel") ||
                               orderType.includes("delivery");
              if (isParcel) {
                const weightVal = currentOrder.actual_weight_kg !== undefined && currentOrder.actual_weight_kg !== null
                  ? currentOrder.actual_weight_kg
                  : currentOrder.weight_category;
                const cleaned = String(weightVal || "0").replace(/[^0-9.]/g, "");
                const weightKg = Number(cleaned) || 0;

                if (weightKg < 10) {
                  return riderVehicle === "bike";
                } else {
                  return riderVehicle === "auto";
                }
              }

              return true;
            }
          );

          if (filteredRiders.length === 0) {
            console.log(`[Dispatch] All nearby riders in Round ${roundConfig.round} have recent active/handled assignments.`);
            continue;
          }

          // Create fresh assignments
          const nowStrTime = new Date().toISOString();
          const expiresAtStr = new Date(Date.now() + timeoutSec * 1000).toISOString();

          const dispatchRows = filteredRiders.map((rider: any) => ({
            order_id: order_id,
            rider_id: rider.rider_id,
            assignment_round: roundConfig.round,
            assignment_status: "sent",
            distance_km: rider.distance_km,
            estimated_earnings: currentOrder.rider_earning,
            sent_at: nowStrTime,
            expires_at: expiresAtStr,
            responded_at: null,
            accepted_at: null,
            rejected_at: null,
            updated_at: nowStrTime,
            last_seen_at: nowStrTime,
            last_seen_fare: currentOrder.rider_earning,
          }));

          // Only upsert and log if we actually have new assignments (Critical Bug #3 and #4 Fixed)
          if (dispatchRows.length > 0) {
            const { error: insertError } = await supabase
              .from("rider_assignments")
              .upsert(dispatchRows, { onConflict: "order_id,rider_id" });

            if (insertError) {
              console.error(`[Dispatch] Error inserting assignments in Round ${roundConfig.round}:`, insertError);
              continue;
            }

            anyAssignmentsSent = true;
            // Final server-side trace point: rider_assignments row committed. Supabase Realtime
            // publishes this INSERT (rider_assignments is in the supabase_realtime publication,
            // see 20260530000002_enable_realtime.sql) to the assigned rider's subscribed channel
            // from here -- everything after this timestamp is client/realtime delivery latency,
            // not server dispatch latency.
            console.log(`[Dispatch] rider_assignments committed for order ${order_id} (round ${roundConfig.round}, ${dispatchRows.length} riders) at ${new Date().toISOString()}. Order age: ${((Date.now() - new Date(currentOrder.created_at).getTime()) / 1000).toFixed(1)}s.`);

            // Create assignment logs
            const logRows = filteredRiders.map((rider: any) => ({
              order_id: order_id,
              rider_id: rider.rider_id,
              assignment_round: roundConfig.round,
              assignment_status: "sent",
              rider_distance_km: rider.distance_km,
              estimated_pickup_time_min: Math.ceil(rider.distance_km * 3),
              sent_at: nowStrTime,
            }));

            const { error: assignmentLogError } = await supabase
              .from("order_assignment_logs")
              .insert(logRows);
            if (assignmentLogError) {
              // rider_assignments is the dispatch source of truth and has already committed above.
              // Keep audit-log failures non-fatal, but no longer discard them silently. A 23505 is
              // the known duplicate (order, rider, round) audit race; other categories remain
              // observable without logging IDs, payloads, or database error details.
              console.warn(
                `[Dispatch] assignment audit insert category=${assignmentLogError.code === "23505" ? "duplicate" : "request_failure"}`,
              );
            }

            console.log(`[Dispatch] Sent Round ${roundConfig.round} to ${filteredRiders.length} riders. Waiting ${timeoutSec}s...`);
            console.log(`[Dispatch] active riders=${filteredRiders.length}`);
            console.log(`[Dispatch] assignments sent=${dispatchRows.length}`);

            // Wait loop checking real-time status and early completion.
            // Combined into a single round trip (get_dispatch_round_status RPC) instead of two
            // separate awaited queries per tick (WayDrop Progressive Degradation Audit, finding
            // EDGE-2).
            //
            // Polled every 3s instead of every 1s (production timeout investigation,
            // 2026-08-07): cuts this loop's DB round trips ~3x. The total wait time is still
            // bounded by the exact same timeoutSec (rider_response_timeout_sec) used everywhere
            // else in this function, so the rider's actual response window and the
            // "unanswered -> expired" deadline right below are byte-for-byte unchanged -- this
            // only changes how often the server checks in on that unchanged deadline. It doesn't
            // delay anything the passenger/rider sees: both sides already get live status from
            // the existing Realtime subscription on orders/rider_assignments, not from this
            // background worker's own tick rate.
            const pollIntervalMs = 3000;
            const roundTimeoutMs = timeoutSec * 1000;
            let roundHandledEarly = false;
            let waitedMs = 0;
            while (waitedMs < roundTimeoutMs) {
              const sleepMs = Math.min(pollIntervalMs, roundTimeoutMs - waitedMs);
              await new Promise((resolve) => setTimeout(resolve, sleepMs));
              waitedMs += sleepMs;

              const roundStatus = await readDispatchRoundStatus(
                () => supabase.rpc(
                  "get_dispatch_round_status",
                  { p_order_id: order_id, p_round: roundConfig.round },
                ),
              );

              if (roundStatus.order_status !== "searching") {
                console.log(`[Dispatch] Order status became ${roundStatus?.order_status || "unknown"}. Stopping dispatch.`);
                return new Response(
                  JSON.stringify({
                    success: true,
                    message: `Order status became ${roundStatus?.order_status || "unknown"}. Stopping dispatch.`,
                  }),
                  {
                    status: 200,
                    headers: { ...corsHeaders, "Content-Type": "application/json" },
                  },
                );
              }

              // Check if there are any remaining "sent" assignments for this round
              if (roundStatus.pending_assignments === 0) {
                console.log(`[Dispatch] All assignments for Round ${roundConfig.round} handled/responded early. Continuing...`);
                roundHandledEarly = true;
                break;
              }
            }

            // Expire remaining unanswered assignments
            if (!roundHandledEarly) {
              console.log(`[Dispatch] Round ${roundConfig.round} timed out. Expiring unanswered assignments...`);
              const expireStr = new Date().toISOString();

              // R12 perf fix: different tables, identical filter shape built entirely from values
              // already known (order_id, roundConfig.round, expireStr) -- neither reads the
              // other's result, neither checks its own error today. Awaited concurrently instead
              // of one at a time.
              await Promise.all([
                supabase
                  .from("rider_assignments")
                  .update({
                    assignment_status: "expired",
                    responded_at: expireStr,
                    updated_at: expireStr,
                    response_type: "ignored",
                    last_response_at: expireStr,
                  })
                  .eq("order_id", order_id)
                  .eq("assignment_round", roundConfig.round)
                  .eq("assignment_status", "sent"),

                supabase
                  .from("order_assignment_logs")
                  .update({
                    assignment_status: "expired",
                    responded_at: expireStr,
                  })
                  .eq("order_id", order_id)
                  .eq("assignment_round", roundConfig.round)
                  .eq("assignment_status", "sent"),
              ]);
            }
          } else {
            console.log(`[Dispatch] Round ${roundConfig.round}: No new assignments to send (riders either busy or in cooldown).`);
          }
        }

        // Wait cooldown before repeating rounds. A flat 15s no-match cooldown meant an
        // already-eligible, already-online rider that Round 1 narrowly missed on the very first
        // pass (e.g. a location heartbeat landing a beat after this pass ran) sat unmatched for a
        // full 15s before the loop even tried again -- this was the dominant contributor to the
        // ~17s gap between order creation and the request appearing on an eligible rider's device.
        // The first few iterations now retry quickly (2s) so a near-miss self-corrects almost
        // immediately; only after several quick attempts does the loop fall back to the slower 15s
        // cadence to avoid hammering the DB for orders that genuinely have no nearby riders yet.
        // Radius/eligibility rules (round_1_radius_km, service_mode, vehicle, KYC, active-order
        // exclusion, etc.) are untouched -- this only changes how soon a miss is retried.
        const earlyRetryIterationLimit = 3;
        let sleepTimeMs: number;
        if (anyAssignmentsSent) {
          sleepTimeMs = 5000;
        } else if (iteration <= earlyRetryIterationLimit) {
          sleepTimeMs = 2000;
        } else {
          sleepTimeMs = 15000;
        }
        console.log(`[Dispatch] Finished Loop Iteration ${iteration}. Sleeping ${sleepTimeMs / 1000}s before next pass.`);
        await new Promise((resolve) => setTimeout(resolve, sleepTimeMs));
      }

      // Check if we should re-trigger asynchronously due to Deno execution timeout
      const { data: checkOrder } = await supabase
        .from("orders")
        .select("order_status")
        .eq("id", order_id)
        .single();

      if (checkOrder && checkOrder.order_status === "searching") {
        console.log("[Dispatch] Safe timeout reached. Releasing lock and re-triggering start-dispatch asynchronously...");
        chainedTriggered = true;

        // RELEASE THE LOCK BEFORE CHAINING so the chained worker can acquire it! (Critical Bug #5 Fixed)
        await supabase
          .from("orders")
          .update({
            dispatch_worker_running: false
          })
          .eq("id", order_id)
          .eq("dispatch_worker_started_at", nowStr); // ONLY release our lock!

        const functionUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/start-dispatch`;
        // Same bounded-fetch reasoning as the fork above: don't let this self-chain call hold
        // the isolate open indefinitely if the network stalls.
        const retriggerPromise = fetchWithTimeout(functionUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
            "apikey": Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
          },
          body: JSON.stringify({ order_id, is_background: true }),
        }, 10000).then((res) => {
          console.log("[Dispatch] Chained start-dispatch successfully, response status:", res.status);
        }).catch((err) => {
          console.error("[Dispatch] Chained start-dispatch failed:", err);
        });

        if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
          (globalThis as any).EdgeRuntime.waitUntil(retriggerPromise);
        }

        return new Response(
          JSON.stringify({
            success: true,
            message: "Re-triggered dispatch asynchronously due to execution limit",
          }),
          {
            status: 200,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }

      return new Response(
        JSON.stringify({
          success: false,
          message: "No riders accepted the order",
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );

    } catch (error) {
      dispatchFailed = true;
      throw error;
    } finally {
      // ONLY release the lock if we didn't chain/trigger the next worker already!
      if (!chainedTriggered) {
        console.log(`[Dispatch] Cleaning up worker lock for order ${order_id}`);
        try {
          const { error: cleanupError } = await supabase
            .from("orders")
            .update({
              dispatch_worker_running: false
            })
            .eq("id", order_id)
            .eq("dispatch_worker_started_at", nowStr); // ONLY release our lock!
          if (cleanupError) {
            // PostgREST resolves database errors unless throwOnError is enabled.
            // Preserve the original dispatch outcome; existing recovery owns a
            // lock that could not be released. Never expose database details.
            console.error("[Dispatch] lock cleanup category=rpc_error");
          }
        } catch {
          console.error("[Dispatch] lock cleanup category=request_exception");
          // A finally exception must not replace an already propagating failure.
          if (!dispatchFailed) throw new DispatchLockCleanupError();
        }
      }
    }
  } catch (error) {
    if (error instanceof DispatchRoundStatusError) {
      console.error(`[Dispatch] round status category=${error.category}`);
      return dispatchRoundStatusFailureResponse(corsHeaders);
    }
    if (error instanceof DispatchLockCleanupError) {
      return new Response(
        JSON.stringify({ success: false, message: error.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    console.error("[Dispatch] unexpected failure category=unexpected_exception");
    return new Response(
      JSON.stringify({
        success: false,
        message: "Dispatch processing unavailable",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
