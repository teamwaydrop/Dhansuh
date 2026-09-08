import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";

Deno.serve(async (req) => {
  try {
    // =====================================================
    // DIRECT TEST MODE
    // =====================================================

    if (req.method === "GET") {
      const authKey = Deno.env.get("MSG91_AUTH_KEY");
      const templateId = Deno.env.get("MSG91_TEMPLATE_ID");

      if (!authKey || !templateId) {
        throw new Error("Missing MSG91 secrets");
      }

      const response = await fetch(
        "https://control.msg91.com/api/v5/flow/",
        {
          method: "POST",
          headers: {
            accept: "application/json",
            "content-type": "application/json",
            authkey: authKey,
          },
          body: JSON.stringify({
            template_id: templateId,
            short_url: "0",
            realTimeResponse: "1",
            recipients: [
              {
                mobiles: "918328330168",
                VAR1: "123456",
              },
            ],
          }),
        },
      );

      const data = await response.text();

      return new Response(
        JSON.stringify({
          status: response.status,
          response: data,
        }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
          },
        },
      );
    }

    // =====================================================
    // VERIFY SUPABASE WEBHOOK
    // =====================================================

    const payload = await req.text();
    const headers = Object.fromEntries(req.headers);

    const hookSecret = Deno.env.get("SEND_SMS_HOOK_SECRET");

    if (!hookSecret) {
      throw new Error("Missing SEND_SMS_HOOK_SECRET");
    }

    const wh = new Webhook(hookSecret);

    const {
      user,
      sms,
    } = wh.verify(payload, headers) as {
      user: {
        phone: string;
      };
      sms: {
        otp: string;
      };
    };

    // =====================================================
    // ENV VARIABLES
    // =====================================================

    const authKey = Deno.env.get("MSG91_AUTH_KEY");
    const templateId = Deno.env.get("MSG91_TEMPLATE_ID");

    if (!authKey || !templateId) {
      throw new Error("Missing MSG91 environment variables");
    }

    // =====================================================
    // FORMAT PHONE
    // =====================================================

    const mobile = user.phone.replace("+", "");

    // SECURITY FIX: never log a real phone number + live login OTP in plaintext -- Supabase
    // Edge Function logs are readable by anyone with project log access, and a live OTP read from
    // there is a full account takeover within its validity window. Log only that a request
    // happened, never the credential itself.
    console.log("============== OTP REQUEST ==============");
    console.log("TEMPLATE:", templateId);

    // =====================================================
    // SEND SMS USING MSG91 FLOW API
    // =====================================================

    const response = await fetch(
      "https://control.msg91.com/api/v5/flow/",
      {
        method: "POST",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          authkey: authKey,
        },
        body: JSON.stringify({
          template_id: templateId,
          short_url: "0",
          realTimeResponse: "1",
          recipients: [
            {
              mobiles: mobile,
              VAR1: String(sms.otp),
            },
          ],
        }),
      },
    );

    const data = await response.text();

    console.log("MSG91 STATUS:", response.status);
    console.log("MSG91 RESPONSE:", data);

    // =====================================================
    // SUCCESS
    // =====================================================

    if (response.ok) {
      return new Response(
        JSON.stringify({
          success: true,
          message: "OTP sent successfully",
          msg91_response: data,
        }),
        {
          status: 200,
          headers: {
            "Content-Type": "application/json",
          },
        },
      );
    }

    // =====================================================
    // FAILURE
    // =====================================================

    return new Response(
      JSON.stringify({
        success: false,
        msg91_status: response.status,
        error: data,
      }),
      {
        status: 400,
        headers: {
          "Content-Type": "application/json",
        },
      },
    );
  } catch (error) {
    console.error("SMS HOOK ERROR:", error);

    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error
          ? error.message
          : "Unknown error",
      }),
      {
        status: 500,
        headers: {
          "Content-Type": "application/json",
        },
      },
    );
  }
});