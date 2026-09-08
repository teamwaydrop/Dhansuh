import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-load-test-key",
};

// Sentinel user id used to tag all mock riders/orders created by this function.
// Every mutation below is scoped to this id so real production data is never touched.
const MOCK_USER_ID = "00000000-0000-0000-0000-000000000000";

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Disabled unless explicitly turned on for a test environment.
  if (Deno.env.get("LOAD_TEST_ENABLED") !== "true") {
    return new Response(
      JSON.stringify({ success: false, error: "load-testing function is disabled" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
    );
  }

  // Admin-only: require a matching shared secret header.
  const expectedAdminKey = Deno.env.get("LOAD_TEST_ADMIN_KEY");
  const providedAdminKey = req.headers.get("x-load-test-key");
  if (!expectedAdminKey || providedAdminKey !== expectedAdminKey) {
    return new Response(
      JSON.stringify({ success: false, error: "Unauthorized" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
    );
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!)["default"]
    );

    const body = await req.json();
    const { action, simulated_rider_count = 50 } = body;

    if (!action) {
      throw new Error("Action is required ('simulate_locations', 'simulate_dispatches', 'cleanup')");
    }

    const startTime = Date.now();
    let resultDetails = {};

    if (action === "simulate_locations") {
      // 1. Fetch existing mock riders only (never real riders), creating more if needed
      let { data: riders, error: fetchError } = await supabase
        .from("riders")
        .select("id")
        .eq("user_id", MOCK_USER_ID)
        .limit(simulated_rider_count);

      if (fetchError) throw fetchError;

      // Seed mock riders if database does not contain enough records
      if (!riders || riders.length < simulated_rider_count) {
        const needed = simulated_rider_count - (riders?.length || 0);
        const mockRiders = [];

        for (let i = 0; i < needed; i++) {
          mockRiders.push({
            user_id: MOCK_USER_ID,
            rating: 4.8,
            total_orders: 10,
            wallet_balance: 100.0,
            account_status: "active",
          });
        }

        const { data: inserted, error: insertError } = await supabase
          .from("riders")
          .insert(mockRiders)
          .select("id");
          
        if (insertError) throw insertError;
        riders = [...(riders || []), ...(inserted || [])];
      }

      // 2. Perform parallel updates simulating GPS telemetry movements
      const gpsUpdates = riders.map((rider: any, index: number) => {
        const angle = (index / riders.length) * 2 * Math.PI;
        // Circular radius around Bangalore center coordinates
        const lat = 12.9715987 + 0.05 * Math.cos(angle) + (Math.random() - 0.5) * 0.002;
        const lng = 77.5945627 + 0.05 * Math.sin(angle) + (Math.random() - 0.5) * 0.002;
        
        return supabase
          .from("riders")
          .update({
            current_lat: lat,
            current_lng: lng,
            current_heading: Math.floor(Math.random() * 360),
            updated_at: new Date().toISOString()
          })
          .eq("id", rider.id);
      });

      await Promise.all(gpsUpdates);
      resultDetails = { riders_updated: riders.length };

    } else if (action === "simulate_dispatches") {
      // Simulate bulk dispatch updates to rider_assignments
      // Create a test order
      const { data: testOrder, error: orderError } = await supabase
        .from("orders")
        .insert({
          user_id: MOCK_USER_ID,
          pickup_address: "Load Test Source",
          destination_address: "Load Test Destination",
          pickup_lat: 12.9715987,
          pickup_lng: 77.5945627,
          destination_lat: 12.90,
          destination_lng: 77.50,
          order_status: "searching",
          order_type: "ride",
          current_fare: 150.00,
        })
        .select("id")
        .single();

      if (orderError) throw orderError;

      const { data: riders } = await supabase
        .from("riders")
        .select("id")
        .eq("user_id", MOCK_USER_ID)
        .limit(simulated_rider_count);
      const assignments = (riders || []).map((rider: any) => ({
        order_id: testOrder.id,
        rider_id: rider.id,
        assignment_status: "sent",
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }));

      const { error: dispatchError } = await supabase.from("rider_assignments").insert(assignments);
      if (dispatchError) throw dispatchError;

      resultDetails = {
        order_id: testOrder.id,
        assignments_count: assignments.length,
      };

    } else if (action === "cleanup") {
      // Cleanup load test assignments & mock riders, scoped strictly to the mock sentinel user
      const { data: mockOrders, error: mockOrdersError } = await supabase
        .from("orders")
        .select("id")
        .eq("user_id", MOCK_USER_ID);

      if (mockOrdersError) throw mockOrdersError;

      const mockOrderIds = (mockOrders || []).map((o: any) => o.id);

      if (mockOrderIds.length > 0) {
        const { error: deleteAssignsError } = await supabase
          .from("rider_assignments")
          .delete()
          .in("order_id", mockOrderIds)
          .eq("assignment_status", "sent");

        if (deleteAssignsError) throw deleteAssignsError;
      }

      const { error: deleteRidersError } = await supabase
        .from("riders")
        .delete()
        .eq("user_id", MOCK_USER_ID);

      if (deleteRidersError) throw deleteRidersError;

      resultDetails = { cleaned: true, mock_orders_scoped: mockOrderIds.length };
    }

    const durationMs = Date.now() - startTime;
    console.log(`[LoadTest] Action: ${action}, Riders: ${simulated_rider_count}, Duration: ${durationMs}ms`);

    // Log telemetry parameters to a table if it exists, otherwise print
    try {
      await supabase.from("load_test_telemetry").insert({
        action,
        rider_count: simulated_rider_count,
        execution_duration_ms: durationMs,
        metadata: resultDetails,
        created_at: new Date().toISOString()
      });
    } catch (_) {
      // Silently pass if table is not migrated yet
    }

    return new Response(
      JSON.stringify({
        success: true,
        action,
        duration_ms: durationMs,
        details: resultDetails,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );

  } catch (error) {
    console.error("LOAD TEST ERROR =>", error);
    return new Response(
      JSON.stringify({ success: false, error: error.message || "Unknown error" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
    );
  }
});
