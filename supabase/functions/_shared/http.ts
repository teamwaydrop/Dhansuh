// Shared helper: fetchWithTimeout
//
// ROOT CAUSE (WayDrop Progressive Degradation Audit, finding EDGE-1): none of this codebase's edge
// functions ever set a timeout or AbortController on an outbound fetch() -- Ola Maps, Cashfree,
// Google OAuth/FCM, and internal function-to-function calls all block for however long the peer
// takes, bounded only by the platform's own opaque gateway timeout. A 20-40s stall on a mobile
// network is already indistinguishable from "never returns" to a user watching a spinner, and
// surfaces client-side as an unbounded wait or a raw connection abort.
//
// This wraps `fetch` with an AbortController-driven timeout so every caller gets a bounded,
// catchable failure (a DOMException named "AbortError") instead of an unbounded hang, while
// leaving the request/response shape, headers, and body completely unchanged for the success path.
export async function fetchWithTimeout(
  input: string | URL | Request,
  init: RequestInit = {},
  timeoutMs = 15000,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

/** Bounds headers AND body consumption for small JSON RPC/provider responses. */
export async function fetchBufferedWithTimeout(input: string | URL | Request, init: RequestInit = {}, timeoutMs = 15000): Promise<Response> {
  const controller = new AbortController();
  const upstream = init.signal ?? (input instanceof Request ? input.signal : undefined);
  const signal = upstream ? AbortSignal.any([controller.signal, upstream]) : controller.signal;
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(input, {...init, signal});
    const bytes = await response.arrayBuffer();
    const noBody = [204,205,304].includes(response.status) || (init.method ?? (input instanceof Request ? input.method : 'GET')) === 'HEAD';
    return new Response(noBody ? null : bytes, {status: response.status, statusText: response.statusText, headers: response.headers});
  } finally { clearTimeout(timer); }
}

export function isTimeoutError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

// For calls that don't go through fetch() directly (e.g. supabase.functions.invoke(), which does
// not accept an AbortSignal across all supabase-js versions this project has pinned to). Bounds how
// long the caller waits; it does not cancel the underlying in-flight request server-side, but it
// guarantees this function's own response is never held hostage by an unbounded downstream call.
export async function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  timeoutMessage = "Operation timed out",
): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const timeoutPromise = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      const err = new Error(timeoutMessage);
      err.name = "AbortError";
      reject(err);
    }, timeoutMs);
  });
  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    clearTimeout(timer!);
  }
}
