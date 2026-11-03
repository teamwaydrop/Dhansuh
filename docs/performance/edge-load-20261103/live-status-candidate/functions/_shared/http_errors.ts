// Minimal typed error so a known business-logic outcome (invalid transition, concurrent-request
// conflict, invalid OTP, authorization failure) can carry its own correct HTTP status/code through
// a thrown exception, instead of being flattened into a generic 500 by a catch-all at the bottom
// of the function -- which is misleading to callers/monitoring and indistinguishable from an
// actual server bug.
//
// Usage: `throw new HttpError(409, "Order status changed by another request. Please retry.", "CONFLICT");`
// then, in the function's outer catch: `if (error instanceof HttpError) { ...use error.status/code... }`.
// Anything NOT thrown as an HttpError falls through to the existing generic 500 path unchanged --
// this only reclassifies errors that were already being intentionally thrown for a known reason.
export class HttpError extends Error {
  readonly status: number;
  readonly code?: string;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

// Shared response builder so every function formats an HttpError (or an unexpected exception) the
// same way: { success: false, error, code? } with the right status, never a blanket 500 for a
// known condition.
export function httpErrorResponse(
  error: unknown,
  corsHeaders: Record<string, string>,
): Response {
  if (error instanceof HttpError) {
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message,
        ...(error.code ? { code: error.code } : {}),
      }),
      {
        status: error.status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  // A malformed request body (`req.json()` throwing) is a client mistake, not a server failure --
  // was previously indistinguishable from a genuine crash once it fell into a catch-all 500.
  if (error instanceof SyntaxError) {
    return new Response(
      JSON.stringify({ success: false, error: "Malformed request body" }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  return new Response(
    JSON.stringify({
      success: false,
      // deno-lint-ignore no-explicit-any
      error: (error as any)?.message ?? String(error) ?? "Unknown error",
    }),
    {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
}
