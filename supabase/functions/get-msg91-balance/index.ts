import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { fetchWithTimeout } from "../_shared/http.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authKey = Deno.env.get("MSG91_AUTH_KEY");
    if (!authKey) {
      return new Response(
        JSON.stringify({ success: false, error: "MSG91_AUTH_KEY secret not configured" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
      );
    }

    const resp = await fetchWithTimeout(`https://control.msg91.com/api/v5/credits?authkey=${authKey}`, {}, 10000);
    const raw  = await resp.json();

    const balance = raw?.balance ?? raw?.credits ?? raw?.data?.balance ?? null;

    return new Response(
      JSON.stringify({ success: true, balance, raw }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ success: false, error: e.message || "Unknown error" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
    );
  }
});