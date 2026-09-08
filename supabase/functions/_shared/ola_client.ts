// Shared helper: getOlaAccessToken / olaRequest
//
// Ola Maps OAuth 2.0 (client-credentials) token acquisition + authenticated request helper for
// any edge function that calls api.olamaps.io on the server side. Token endpoint, grant type,
// and header format are Ola Krutrim's documented OAuth 2.0 flow (maps.olakrutrim.com/docs/auth,
// cross-checked against Ola's own published Postman collection and SDK source, since the docs
// page itself renders the exact values inside copy-to-clipboard widgets that aren't present in a
// plain fetch): POST to a Keycloak-backed token endpoint with
// grant_type=client_credentials, then `Authorization: Bearer <access_token>` on the Maps API
// calls themselves (no api_key query param needed once using OAuth). Re-verify against the
// Ola Krutrim developer portal if the first live token/API call in Step 8 testing fails.
//
// OLA_CLIENT_ID / OLA_CLIENT_SECRET are read only via Deno.env.get() -- never logged, never
// echoed in any thrown error message, and never returned to the Flutter client. The access token
// itself is also never returned to the client; it only ever travels from this module straight
// into the Authorization header of a server-side request to api.olamaps.io.

import { fetchWithTimeout, isTimeoutError } from "./http.ts";
import { HttpError } from "./http_errors.ts";

const OLA_TOKEN_URL =
  "https://account.olamaps.io/realms/olamaps/protocol/openid-connect/token";
const OLA_API_BASE = "https://api.olamaps.io";
const TOKEN_REQUEST_TIMEOUT_MS = 8000;
// Refresh a little before the token's real expiry so an in-flight request never races a token
// that goes stale mid-request.
const EXPIRY_SAFETY_MARGIN_MS = 60_000;
// If Ola's response is missing/malformed expires_in, assume a conservative short lifetime rather
// than caching an unknown-duration token indefinitely.
const FALLBACK_TTL_SECONDS = 300;

type CachedToken = { accessToken: string; expiresAt: number };

// Isolate-scoped in-memory cache only (same pattern as eta_cache.ts / signed_url_cache.ts) --
// never persisted to disk, KV, or the database, so it cannot leak via any storage layer and is
// automatically gone when the isolate recycles.
let cachedToken: CachedToken | null = null;
// Collapses concurrent cold-start callers onto a single in-flight token request instead of firing
// N parallel OAuth calls the first time N requests land in the same warm isolate at once.
let inFlightTokenRequest: Promise<string> | null = null;

function readOlaCredentials(): { clientId: string; clientSecret: string } {
  const clientId = Deno.env.get("OLA_CLIENT_ID");
  const clientSecret = Deno.env.get("OLA_CLIENT_SECRET");

  if (!clientId || !clientSecret) {
    throw new HttpError(
      500,
      "Ola Maps OAuth is not configured on the server.",
      "OLA_OAUTH_NOT_CONFIGURED",
    );
  }

  return { clientId, clientSecret };
}

async function requestNewAccessToken(): Promise<string> {
  const { clientId, clientSecret } = readOlaCredentials();

  let response: Response;
  try {
    response = await fetchWithTimeout(
      OLA_TOKEN_URL,
      {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "client_credentials",
          scope: "openid",
          client_id: clientId,
          client_secret: clientSecret,
        }).toString(),
      },
      TOKEN_REQUEST_TIMEOUT_MS,
    );
  } catch (networkError) {
    console.error(
      "OLA OAUTH TOKEN REQUEST FAILED =>",
      isTimeoutError(networkError) ? "timed out" : String(networkError),
    );
    throw new HttpError(
      502,
      "Could not reach Ola Maps authentication service.",
      "OLA_OAUTH_NETWORK_ERROR",
    );
  }

  // deno-lint-ignore no-explicit-any
  let body: any;
  try {
    body = await response.json();
  } catch {
    throw new HttpError(
      502,
      "Ola Maps authentication service returned a malformed response.",
      "OLA_OAUTH_MALFORMED_RESPONSE",
    );
  }

  if (!response.ok) {
    // error / error_description are standard OAuth error fields, never the credentials
    // themselves -- the credentials were only ever in the outbound request body, which this
    // catch block never logs.
    const detail = body?.error_description ?? body?.error ?? "no error detail in body";
    console.error(`OLA OAUTH TOKEN HTTP ERROR ${response.status} =>`, detail);

    // A 401/403 here means OUR client_id/client_secret were rejected -- that is a server
    // misconfiguration, not something the calling passenger/rider did, so it is surfaced to
    // Flutter as a generic 500 rather than a 401/403 (which would misleadingly suggest the
    // end-user's own session/auth is the problem).
    throw new HttpError(
      response.status === 401 || response.status === 403 ? 500 : 502,
      "Ola Maps authentication failed.",
      "OLA_OAUTH_REJECTED",
    );
  }

  const accessToken = body?.access_token;
  if (typeof accessToken !== "string" || accessToken.length === 0) {
    throw new HttpError(
      502,
      "Ola Maps authentication service did not return an access token.",
      "OLA_OAUTH_NO_TOKEN",
    );
  }

  const expiresIn = typeof body?.expires_in === "number" && body.expires_in > 0
    ? body.expires_in
    : FALLBACK_TTL_SECONDS;

  cachedToken = {
    accessToken,
    expiresAt: Date.now() + expiresIn * 1000,
  };

  return accessToken;
}

/** Returns a valid Ola Maps OAuth access token, reusing a cached one until it's close to expiry. */
export async function getOlaAccessToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedToken.expiresAt - EXPIRY_SAFETY_MARGIN_MS) {
    return cachedToken.accessToken;
  }

  if (!inFlightTokenRequest) {
    inFlightTokenRequest = requestNewAccessToken().finally(() => {
      inFlightTokenRequest = null;
    });
  }

  return inFlightTokenRequest;
}

export interface OlaRequestOptions {
  method?: string;
  query?: Record<string, string | number | undefined>;
  timeoutMs?: number;
  headers?: Record<string, string>;
}

/**
 * Makes an OAuth-authenticated request to an Ola Maps API endpoint (path relative to
 * https://api.olamaps.io, e.g. "/routing/v1/distanceMatrix/basic"). Automatically fetches/caches
 * the access token and retries exactly once with a forced-fresh token if Ola rejects it as
 * expired/invalid (401/403), so a token that expires between our cache check and Ola's own
 * validation doesn't surface as a hard failure. Throws HttpError with a safe, secret-free message
 * on any failure -- callers should let that propagate to their own catch block (see
 * http_errors.ts's httpErrorResponse) or handle it explicitly for a graceful-degradation path.
 */
export async function olaRequest(
  path: string,
  options: OlaRequestOptions = {},
): Promise<unknown> {
  const url = new URL(path.startsWith("http") ? path : `${OLA_API_BASE}${path}`);
  if (options.query) {
    for (const [key, value] of Object.entries(options.query)) {
      if (value !== undefined) url.searchParams.set(key, String(value));
    }
  }

  for (let attempt = 1; attempt <= 2; attempt++) {
    const accessToken = await getOlaAccessToken();

    let response: Response;
    try {
      response = await fetchWithTimeout(
        url.toString(),
        {
          method: options.method ?? "GET",
          headers: {
            "Authorization": `Bearer ${accessToken}`,
            "X-Request-Id": crypto.randomUUID(),
            ...options.headers,
          },
        },
        options.timeoutMs ?? 8000,
      );
    } catch (networkError) {
      console.error(
        "OLA API REQUEST FAILED =>",
        path,
        isTimeoutError(networkError) ? "timed out" : String(networkError),
      );
      throw new HttpError(
        isTimeoutError(networkError) ? 504 : 502,
        isTimeoutError(networkError) ? "Ola Maps request timed out." : "Could not reach Ola Maps.",
        isTimeoutError(networkError) ? "OLA_API_TIMEOUT" : "OLA_API_NETWORK_ERROR",
      );
    }

    if ((response.status === 401 || response.status === 403) && attempt === 1) {
      // Our cached token was rejected -- force a fresh one and retry exactly once.
      cachedToken = null;
      continue;
    }

    // deno-lint-ignore no-explicit-any
    let body: any;
    try {
      body = await response.json();
    } catch {
      throw new HttpError(
        502,
        "Ola Maps returned a malformed response.",
        "OLA_API_MALFORMED_RESPONSE",
      );
    }

    if (!response.ok) {
      const apiMessage = body?.error_message ?? body?.message ?? body?.status ??
        "no error detail in body";
      console.error(`OLA API HTTP ERROR ${response.status} =>`, path, apiMessage);

      throw new HttpError(
        response.status === 429 ? 429 : response.status >= 500 ? 502 : 500,
        `Ola Maps API error (${response.status}): ${apiMessage}`,
        "OLA_API_ERROR",
      );
    }

    return body;
  }

  // Unreachable in practice (the loop always returns or throws above) -- satisfies the compiler
  // and gives a safe, generic failure if it ever were reached.
  throw new HttpError(502, "Ola Maps request failed.", "OLA_API_ERROR");
}
