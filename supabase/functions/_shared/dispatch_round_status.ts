export type DispatchRoundStatusFailureCategory =
  | "rpc_error"
  | "rpc_exception"
  | "empty_response"
  | "invalid_response";

export class DispatchRoundStatusError extends Error {
  constructor(readonly category: DispatchRoundStatusFailureCategory) {
    super("Dispatch round status unavailable");
    this.name = "DispatchRoundStatusError";
  }
}

export interface DispatchRoundStatus {
  order_status: string | null;
  pending_assignments: number;
}

// The SQL RPC always returns one row, even when the order does not exist.
// Operational failure must not be interpreted as that legitimate null status.
export async function readDispatchRoundStatus(
  fetchStatus: () => PromiseLike<unknown>,
): Promise<DispatchRoundStatus> {
  let response: unknown;
  try {
    response = await fetchStatus();
  } catch {
    throw new DispatchRoundStatusError("rpc_exception");
  }
  if (response === null || typeof response !== "object" ||
      !("data" in response) || !("error" in response)) {
    throw new DispatchRoundStatusError("invalid_response");
  }
  // Error takes precedence even if a contradictory response also contains data.
  if (response.error !== null && response.error !== undefined) {
    throw new DispatchRoundStatusError("rpc_error");
  }
  const rows = response.data;
  if (Array.isArray(rows) && rows.length === 0) {
    throw new DispatchRoundStatusError("empty_response");
  }
  if (!Array.isArray(rows) || rows.length !== 1) {
    throw new DispatchRoundStatusError("invalid_response");
  }
  const row: unknown = rows[0];
  if (row === null || typeof row !== "object" || Array.isArray(row) ||
      !("order_status" in row) || !("pending_assignments" in row)) {
    throw new DispatchRoundStatusError("invalid_response");
  }
  const status = row.order_status;
  const pending = row.pending_assignments;
  if ((status !== null && (typeof status !== "string" || status.length === 0)) ||
      typeof pending !== "number" || !Number.isSafeInteger(pending) || pending < 0) {
    throw new DispatchRoundStatusError("invalid_response");
  }
  return { order_status: status, pending_assignments: pending };
}

export function dispatchRoundStatusFailureResponse(
  headers: Record<string, string>,
): Response {
  return new Response(
    JSON.stringify({ success: false, message: "Dispatch round status unavailable" }),
    { status: 500, headers: { ...headers, "Content-Type": "application/json" } },
  );
}
