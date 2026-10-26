import {
  DispatchRoundStatusError,
  readDispatchRoundStatus,
} from "./dispatch_round_status.ts";
import { PostgrestClient } from "https://esm.sh/@supabase/postgrest-js@2.112.2/denonext/postgrest-js.mjs";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const row = (status: string | null, pending = 0) => ({
  data: [{ order_status: status, pending_assignments: pending }], error: null,
});
const privateMarker = "synthetic_private_rpc_detail";
const cleanupPrivateMarker = "synthetic_private_cleanup_detail";

Deno.test("cached SDK: cleanup database errors resolve unless throwOnError is enabled", async () => {
  const client = new PostgrestClient("http://local.invalid/rest/v1", {
    fetch: () => Promise.resolve(new Response(
      JSON.stringify({ code: "42501", message: cleanupPrivateMarker }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    )),
  });
  const result = await client.from("orders").update({ dispatch_worker_running: false });
  assert(result.error?.code === "42501" && result.data === null, "SDK did not resolve the database error");
  let rejected = false;
  try {
    await client.from("orders").update({ dispatch_worker_running: false }).throwOnError();
  } catch {
    rejected = true;
  }
  assert(rejected, "Explicit throwOnError did not reject");
});

const failures = [
  { name: "RPC error/null data", response: { data: null, error: { message: privateMarker } }, category: "rpc_error" },
  { name: "RPC error takes precedence over non-null data", response: { ...row("accepted"), error: { message: privateMarker } }, category: "rpc_error" },
  { name: "empty rows", response: { data: [], error: null }, category: "empty_response" },
  { name: "null data without error", response: { data: null, error: null }, category: "invalid_response" },
  { name: "multiple rows", response: { data: [row("searching").data[0], row("accepted").data[0]], error: null }, category: "invalid_response" },
  { name: "malformed row", response: { data: [null], error: null }, category: "invalid_response" },
  { name: "missing assignment count", response: { data: [{ order_status: "searching" }], error: null }, category: "invalid_response" },
  { name: "null assignment count", response: { data: [{ order_status: "searching", pending_assignments: null }], error: null }, category: "invalid_response" },
  { name: "string assignment count", response: { data: [{ order_status: "searching", pending_assignments: "0" }], error: null }, category: "invalid_response" },
  { name: "negative assignment count", response: row("searching", -1), category: "invalid_response" },
  { name: "fractional assignment count", response: row("searching", 0.5), category: "invalid_response" },
  { name: "missing order status", response: { data: [{ pending_assignments: 0 }], error: null }, category: "invalid_response" },
];

for (const failure of failures) {
  Deno.test(`classification: ${failure.name}`, async () => {
    try {
      await readDispatchRoundStatus(() => Promise.resolve(failure.response));
      throw new Error("Expected classified failure");
    } catch (error) {
      assert(error instanceof DispatchRoundStatusError, "Wrong failure type");
      assert(error.category === failure.category, "Wrong sanitized category");
      assert(!error.message.includes(privateMarker), "Private detail leaked");
    }
  });
}

// Execute the actual start-dispatch handler body. Only its external service
// factory/server/env imports are replaced. Relative shared helpers remain real.
// Run without --allow-net, --allow-env or --allow-write: no production access.
type Handler = (request: Request) => Promise<Response>;
const entry = new URL("../start-dispatch/index.ts", import.meta.url);
const source = Deno.readTextFileSync(entry);
const adapted = source
  .replace(/^import \{ serve \}[^\n]*\n/m, "")
  .replace(/^import \{ createClient \}[^\n]*\n/m, "")
  .replaceAll(/from "(\.\.[^"]+)"/g, (_match, path: string) =>
    `from "${new URL(path, entry).href}"`)
  .replaceAll("Deno.env.get(", "testEnv.get(");
const shim = `
export let capturedHandler;
let client;
export function setClient(value) { client = value; }
const serve = handler => { capturedHandler = handler; };
const createClient = () => client;
const testEnv = { get: () => 'synthetic-local-only' };
`;
const module = await import(
  `data:application/typescript,${encodeURIComponent(shim + adapted)}`
) as { capturedHandler: Handler; setClient(client: FakeClient): void };
assert(typeof module.capturedHandler === "function", "Handler was not captured");

interface Result { data: unknown; error: { code: string; message: string } | null }
class Query implements PromiseLike<Result> {
  operation: "select" | "upsert" | "insert" = "select";
  patch: Record<string, unknown> | null = null;
  filters = new Map<string, unknown>();
  constructor(readonly client: FakeClient, readonly table: string) {}
  select(_columns?: string) { return this; }
  eq(column: string, value: unknown) { this.filters.set(column, value); return this; }
  or(_expression: string) { return this; }
  update(patch: Record<string, unknown>) { this.patch = patch; return this; }
  upsert(_rows: unknown, _options: unknown) { this.operation = "upsert"; return this; }
  insert(_rows: unknown) { this.operation = "insert"; return this; }
  single() { return this; }
  maybeSingle() { return this; }
  then<TResult1 = Result, TResult2 = never>(
    fulfilled?: ((value: Result) => TResult1 | PromiseLike<TResult1>) | null,
    rejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return Promise.resolve().then(() => this.client.execute(this)).then(fulfilled, rejected);
  }
}

class FakeClient {
  clock = Date.now();
  createdAt = new Date(this.clock).toISOString();
  orderStatus = "searching";
  lockRunning = false;
  lockStamp: unknown = null;
  acquiredStamp: unknown = null;
  cleanupFilters: unknown[] = [];
  expirationWrites = 0;
  roundCalls = 0;
  sleeps: number[] = [];
  logs: string[] = [];
  replaceLock = false;
  nearbyException: unknown = null;
  assignmentReadData: unknown = [];
  assignmentReadError: Result["error"] = null;
  assignmentReadException: unknown = null;
  assignmentUpserts = 0;
  matchingCalls = 0;
  matchingExclusions: string[] = [];
  finishAfterMatching = false;
  cleanupMode: "success" | "reject" | "resolved_error" = "success";
  constructor(readonly fetchRound: () => Promise<unknown>) {}
  auth = { getUser: () => Promise.resolve({
    data: { user: { id: "synthetic-owner" } }, error: null,
  }) };
  from(table: string) { return new Query(this, table); }
  async rpc(name: string, _args: unknown) {
    if (name === "find_nearby_riders") {
      this.matchingCalls++;
      if (_args !== null && typeof _args === "object" &&
          "p_excluded_rider_ids" in _args && Array.isArray(_args.p_excluded_rider_ids)) {
        this.matchingExclusions = _args.p_excluded_rider_ids.map(String);
      }
      if (this.finishAfterMatching) this.orderStatus = "accepted";
      if (this.nearbyException !== null) throw this.nearbyException;
      return { data: [{ rider_id: "synthetic-rider", vehicle_type: "bike", distance_km: 1 }], error: null };
    }
    assert(name === "get_dispatch_round_status", "Unexpected RPC");
    this.roundCalls++;
    if (this.replaceLock) {
      this.lockRunning = true;
      this.lockStamp = "replacement-worker";
    }
    return await this.fetchRound();
  }
  execute(query: Query): Result {
    if (query.patch) {
      if (query.table === "orders") {
        if (query.patch.dispatch_worker_running === true) {
          assert(!this.lockRunning, "Duplicate fake lock acquisition");
          this.lockRunning = true;
          this.lockStamp = query.patch.dispatch_worker_started_at;
          this.acquiredStamp = this.lockStamp;
        } else if (query.patch.dispatch_worker_running === false) {
          const stamp = query.filters.get("dispatch_worker_started_at");
          this.cleanupFilters.push(stamp);
          assert(query.filters.get("id") === "synthetic-order", "Cleanup lost order-ID filter");
          if (this.cleanupMode === "reject") throw new Error(cleanupPrivateMarker);
          if (this.cleanupMode === "resolved_error") {
            return { data: null, error: { code: "42501", message: cleanupPrivateMarker } };
          }
          if (stamp === this.lockStamp) this.lockRunning = false;
        }
      } else if (query.table === "rider_assignments" || query.table === "order_assignment_logs") {
        this.expirationWrites++;
      }
      return { data: { id: "synthetic-order" }, error: null };
    }
    if (query.operation === "upsert" && query.table === "rider_assignments") {
      this.assignmentUpserts++;
      return { data: [], error: null };
    }
    if (query.operation === "select" && query.table === "rider_assignments") {
      if (this.assignmentReadException !== null) throw this.assignmentReadException;
      return { data: this.assignmentReadData, error: this.assignmentReadError };
    }
    if (query.table === "dispatch_config") return { data: {
      rider_response_timeout_sec: 6, round_1_radius_km: 1,
      round_1_batch_size: 1, round_2_trigger_after_sec: 9999,
      allow_round_3: false,
    }, error: null };
    if (query.table === "orders") return { data: {
      id: "synthetic-order", user_id: "synthetic-owner", rider_id: null,
      order_type: "ride", order_status: this.orderStatus, created_at: this.createdAt,
      dispatch_state: {}, pickup_lat: 0, pickup_lng: 0, rider_earning: 1,
      vehicle_type: "bike", dispatch_worker_running: this.lockRunning,
      dispatch_worker_started_at: this.lockStamp,
    }, error: null };
    assert(query.table === "rider_assignments" || query.table === "order_assignment_logs", "Unexpected table");
    return { data: [], error: null };
  }
}

async function run(client: FakeClient): Promise<Response> {
  const timer = Object.getOwnPropertyDescriptor(globalThis, "setTimeout")!;
  const now = Date.now;
  const log = console.log;
  const error = console.error;
  module.setClient(client);
  Date.now = () => client.clock;
  const capture = (...args: unknown[]) => client.logs.push(args.map(String).join(" "));
  console.log = capture;
  console.error = capture;
  Object.defineProperty(globalThis, "setTimeout", {
    configurable: true, writable: true,
    value: (callback: () => void, milliseconds: number) => {
      client.sleeps.push(milliseconds);
      client.clock += milliseconds;
      queueMicrotask(callback);
      return 0;
    },
  });
  try {
    return await module.capturedHandler(new Request("http://local.invalid", {
      method: "POST", headers: { Authorization: "Bearer synthetic-user-session" },
      body: JSON.stringify({ order_id: "synthetic-order", is_background: true }),
    }));
  } finally {
    Object.defineProperty(globalThis, "setTimeout", timer);
    Date.now = now;
    console.log = log;
    console.error = error;
  }
}

for (const failure of failures.slice(0, 8)) {
  Deno.test(`handler: ${failure.name} fails safely without expiration`, async () => {
    const client = new FakeClient(() => Promise.resolve(failure.response));
    const response = await run(client);
    const text = await response.text();
    const body = JSON.parse(text);
    assert(response.status === 500 && body.success === false, "Failure reported as success");
    assert(body.message === "Dispatch round status unavailable", "Unsafe error message");
    assert(!text.includes(privateMarker) && !client.logs.join(" ").includes(privateMarker), "Private detail leaked");
    assert(client.logs.some(log => log.includes(`category=${failure.category}`)), "Failure category missing");
    assert(client.roundCalls === 1 && client.sleeps.join() === "3000", "Unexpected retry/cadence");
    assert(client.expirationWrites === 0, "Failure expired assignments");
    assert(!client.lockRunning && client.cleanupFilters[0] === client.acquiredStamp, "Owned lock not released");
  });
}

Deno.test("handler: thrown RPC exception is sanitized and releases own lock", async () => {
  const client = new FakeClient(() => Promise.reject(new Error(privateMarker)));
  const response = await run(client);
  assert(response.status === 500 && (await response.json()).success === false, "Exception reported as success");
  assert(client.logs.some(log => log.includes("category=rpc_exception")), "Exception category missing");
  assert(!client.logs.join().includes(privateMarker), "Exception detail leaked");
  assert(client.expirationWrites === 0 && !client.lockRunning, "Exception cleanup failed");
});

for (const status of [null, "accepted", "cancelled", "expired"]) {
  Deno.test(`handler: valid status ${status} preserves successful stop`, async () => {
    const client = new FakeClient(() => Promise.resolve(row(status)));
    const response = await run(client);
    const body = await response.json();
    assert(response.status === 200 && body.success === true, "Valid stop changed");
    assert(body.message === `Order status became ${status || "unknown"}. Stopping dispatch.`, "Legacy message changed");
    assert(client.expirationWrites === 0 && !client.lockRunning, "Terminal cleanup failed");
  });
}

Deno.test("handler: searching/pending keeps the same cadence until accepted", async () => {
  let client: FakeClient;
  client = new FakeClient(() => Promise.resolve(row(client.roundCalls === 1 ? "searching" : "accepted", 1)));
  const response = await run(client);
  assert(response.status === 200 && (await response.json()).success === true, "Pending path failed");
  assert(client.roundCalls === 2 && client.sleeps.join() === "3000,3000", "Polling cadence changed");
  assert(client.expirationWrites === 0, "Pending assignments expired early");
});

Deno.test("handler: searching/zero advances without expiring that round", async () => {
  let client: FakeClient;
  client = new FakeClient(() => {
    client.orderStatus = "accepted"; // Accepted before the next outer-loop read.
    return Promise.resolve(row("searching", 0));
  });
  const response = await run(client);
  assert(response.status === 200 && (await response.json()).success === true, "Zero-pending path failed");
  assert(client.roundCalls === 1 && client.sleeps.join() === "3000,5000", "Existing cooldown changed");
  assert(client.expirationWrites === 0, "Handled round expired assignments");
});

Deno.test("handler: failed status read cannot release a replacement worker lock", async () => {
  const client = new FakeClient(() => Promise.resolve({ data: null, error: { message: privateMarker } }));
  client.replaceLock = true;
  const response = await run(client);
  assert(response.status === 500, "Expected operational failure");
  assert(client.cleanupFilters[0] === client.acquiredStamp, "Cleanup lost ownership filter");
  assert(client.lockRunning && client.lockStamp === "replacement-worker", "Released another worker lock");
  await response.body?.cancel();
});

for (const cleanupMode of ["reject", "resolved_error"] as const) {
  for (const category of ["rpc_error", "rpc_exception", "empty_response"] as const) {
    Deno.test(`handler: ${category} survives cleanup ${cleanupMode} without private details`, async () => {
      const client = new FakeClient(() => category === "rpc_exception"
        ? Promise.reject(new Error(privateMarker))
        : Promise.resolve(category === "rpc_error"
          ? { data: null, error: { message: privateMarker } }
          : { data: [], error: null }));
      client.cleanupMode = cleanupMode;
      const response = await run(client);
      const text = await response.text();
      const body = JSON.parse(text);
      assert(response.status === 500 && body.success === false, "Failure reported as success");
      assert(body.message === "Dispatch round status unavailable", "Original classified failure was replaced");
      const logs = client.logs.join(" ");
      assert(logs.includes(`round status category=${category}`), "Original category lost");
      assert(logs.includes(`lock cleanup category=${cleanupMode === "reject" ? "request_exception" : "rpc_error"}`), "Cleanup category missing");
      assert(![privateMarker, cleanupPrivateMarker].some(marker => text.includes(marker) || logs.includes(marker)), "Private details leaked");
      assert(client.expirationWrites === 0 && client.roundCalls === 1, "Failure changed dispatch work");
      assert(client.cleanupFilters.length === 1 && client.cleanupFilters[0] === client.acquiredStamp, "Cleanup changed ownership or retried");
      assert(client.lockRunning, "Failed cleanup falsely released lock");
    });
  }
}

Deno.test("handler: rejected cleanup after valid stop is sanitized", async () => {
  const client = new FakeClient(() => Promise.resolve(row("accepted")));
  client.cleanupMode = "reject";
  const response = await run(client);
  const text = await response.text();
  const body = JSON.parse(text);
  assert(response.status === 500 && body.success === false, "Cleanup rejection changed status behavior");
  assert(body.message === "Dispatch lock cleanup unavailable", "Unsafe cleanup response");
  assert(!text.includes(cleanupPrivateMarker) && !client.logs.join().includes(cleanupPrivateMarker), "Cleanup detail leaked");
  assert(client.expirationWrites === 0 && client.cleanupFilters.length === 1, "Cleanup changed dispatch work");
});

Deno.test("handler: resolved cleanup error preserves valid terminal response", async () => {
  const client = new FakeClient(() => Promise.resolve(row("accepted")));
  client.cleanupMode = "resolved_error";
  const response = await run(client);
  const body = await response.json();
  assert(response.status === 200 && body.success === true, "Resolved cleanup error changed legacy outcome");
  assert(body.message === "Order status became accepted. Stopping dispatch.", "Terminal response changed");
  assert(client.logs.some(log => log.includes("lock cleanup category=rpc_error")), "Resolved cleanup error not recorded");
  assert(!client.logs.join().includes(cleanupPrivateMarker), "Resolved cleanup detail leaked");
  assert(client.lockRunning && client.cleanupFilters.length === 1, "Failed cleanup falsely released lock or retried");
});

for (const kind of ["error", "object", "string"] as const) {
  Deno.test(`handler: unexpected ${kind} failure is sanitized and cleans up its own lock`, async () => {
    const client = new FakeClient(() => Promise.resolve(row("accepted")));
    let stringified = false;
    const failure = kind === "error" ? new Error(privateMarker)
      : kind === "string" ? privateMarker
      : { message: privateMarker, details: cleanupPrivateMarker, toString() {
        stringified = true;
        return privateMarker;
      } };
    if (failure instanceof Error) failure.stack = cleanupPrivateMarker;
    client.nearbyException = failure;
    const response = await run(client);
    const text = await response.text();
    const body = JSON.parse(text);
    assert(response.status === 500 && body.success === false, "Unexpected failure status changed");
    assert(body.message === "Dispatch processing unavailable", "Unsafe fallback response");
    assert(Object.keys(body).sort().join() === "message,success", "Response contract changed");
    assert(response.headers.get("Content-Type") === "application/json", "Content type changed");
    assert(response.headers.get("Access-Control-Allow-Origin") === "*", "CORS changed");
    const logs = client.logs.join(" ");
    assert(logs.includes("category=unexpected_exception"), "Bounded category missing");
    assert(![privateMarker, cleanupPrivateMarker].some(marker => text.includes(marker) || logs.includes(marker)), "Private message or stack leaked");
    assert(!stringified, "Fallback evaluated exception details");
    assert(client.expirationWrites === 0 && client.roundCalls === 0 && client.sleeps.length === 0, "Unexpected failure changed dispatch work");
    assert(!client.lockRunning && client.cleanupFilters.length === 1 && client.cleanupFilters[0] === client.acquiredStamp, "Owned cleanup changed");
  });
}

Deno.test("handler: unexpected failure remains sanitized when cleanup also rejects", async () => {
  const client = new FakeClient(() => Promise.resolve(row("accepted")));
  client.nearbyException = new Error(privateMarker);
  client.cleanupMode = "reject";
  const response = await run(client);
  const text = await response.text();
  const body = JSON.parse(text);
  assert(response.status === 500 && body.success === false && body.message === "Dispatch processing unavailable", "Original fallback outcome replaced");
  const logs = client.logs.join(" ");
  assert(logs.includes("category=unexpected_exception") && logs.includes("lock cleanup category=request_exception"), "Failure categories lost");
  assert(![privateMarker, cleanupPrivateMarker].some(marker => text.includes(marker) || logs.includes(marker)), "Combined failure leaked details");
  assert(client.lockRunning && client.cleanupFilters.length === 1 && client.expirationWrites === 0, "Combined failure changed cleanup or assignments");
});

Deno.test("recovery safety: a live worker can still poll after its 120-second lock age", async () => {
  let client: FakeClient;
  let observedLiveStaleLock = false;
  client = new FakeClient(() => {
    if (client.roundCalls === 1) {
      // Simulate latency without sleeping. The in-flight RPC completes after
      // the current takeover threshold, while this worker still owns its lock.
      client.clock = Date.parse(String(client.lockStamp)) + 121_000;
      observedLiveStaleLock = client.lockRunning;
      return Promise.resolve(row("searching", 1));
    }
    assert(client.lockRunning, "Worker unexpectedly stopped before the next poll");
    assert(client.clock - Date.parse(String(client.lockStamp)) > 120_000,
      "Expected expired timestamp on a still-running worker");
    return Promise.resolve(row("accepted"));
  });
  const response = await run(client);
  assert(response.status === 200 && (await response.json()).success === true,
    "Expected existing valid terminal response");
  assert(observedLiveStaleLock && client.roundCalls === 2,
    "The current timestamp alone did not demonstrate the liveness ambiguity");
  assert(client.expirationWrites === 0 && !client.lockRunning,
    "Safety investigation changed normal terminal cleanup");
});

for (const kind of ["resolved_null", "resolved_data", "thrown", "null_success", "object_success"] as const) {
  Deno.test(`assignment history: ${kind} aborts before matching or writes`, async () => {
    const client = new FakeClient(() => Promise.resolve(row("accepted")));
    if (kind === "thrown") client.assignmentReadException = new Error(privateMarker);
    if (kind === "resolved_null" || kind === "resolved_data") {
      client.assignmentReadError = { code: "57014", message: privateMarker };
    }
    client.assignmentReadData = kind === "resolved_data"
      ? [{ rider_id: "synthetic-rider", assignment_status: "sent" }]
      : kind === "object_success" ? {} : null;
    const response = await run(client);
    const text = await response.text();
    const body = JSON.parse(text);
    assert(response.status === 500 && body.success === false && body.message === "Dispatch processing unavailable", "Failed history read reported as success");
    assert(!text.includes(privateMarker) && !client.logs.join().includes(privateMarker), "History error leaked");
    assert(client.matchingCalls === 0 && client.assignmentUpserts === 0 && client.expirationWrites === 0, "Failed history read reached matching or assignment writes");
    assert(client.roundCalls === 0 && client.sleeps.length === 0, "Added retries or polling");
    assert(!client.lockRunning && client.cleanupFilters[0] === client.acquiredStamp, "Owned cleanup changed");
    if (kind !== "thrown") {
      const category = kind.startsWith("resolved") ? "request_error" : "invalid_response";
      assert(client.logs.some(log => log.includes(`assignment history category=${category}`)), "History category missing");
    }
  });
}

Deno.test("assignment history: a successful empty array preserves normal matching", async () => {
  const client = new FakeClient(() => Promise.resolve(row("accepted")));
  const response = await run(client);
  assert(response.status === 200 && (await response.json()).success === true, "Empty history rejected");
  assert(client.matchingCalls === 1 && client.assignmentUpserts === 1 && client.roundCalls === 1, "Normal matching changed");
  assert(client.matchingExclusions.length === 0 && client.expirationWrites === 0, "Empty-history behavior changed");
});

for (const status of ["sent", "accepted", "rejected", "expired"]) {
  Deno.test(`assignment history: existing ${status} exclusion remains effective`, async () => {
    const client = new FakeClient(() => Promise.resolve(row("accepted")));
    client.assignmentReadData = [{
      rider_id: "synthetic-rider", assignment_status: status,
      responded_at: null,
      hidden_until: new Date(client.clock + 60_000).toISOString(),
      last_seen_fare: 1, estimated_earnings: 1,
    }];
    client.finishAfterMatching = true;
    const response = await run(client);
    assert(response.status === 200 && (await response.json()).success === true, "Existing terminal behavior changed");
    assert(client.matchingExclusions.includes("synthetic-rider"), "Existing exclusion rule lost");
    assert(client.assignmentUpserts === 0 && client.expirationWrites === 0 && client.roundCalls === 0, "Handled rider was re-offered");
  });
}

const validHistoryRow = {
  rider_id: "synthetic-rider", assignment_status: "sent",
  responded_at: null, hidden_until: null, last_seen_fare: null, estimated_earnings: null,
};
const malformedHistoryMembers: unknown[] = [
  null, undefined, "unexpected", 1, true, [], {},
  { ...validHistoryRow, rider_id: null },
  { ...validHistoryRow, rider_id: " " },
  { ...validHistoryRow, assignment_status: undefined },
  { ...validHistoryRow, assignment_status: "unknown" },
  { ...validHistoryRow, responded_at: undefined },
  { ...validHistoryRow, responded_at: "invalid" },
  { ...validHistoryRow, hidden_until: {} },
  { ...validHistoryRow, last_seen_fare: undefined },
  { ...validHistoryRow, last_seen_fare: "" },
  { ...validHistoryRow, last_seen_fare: "not-a-number" },
  { ...validHistoryRow, last_seen_fare: Infinity },
  { ...validHistoryRow, estimated_earnings: true },
  { ...validHistoryRow, estimated_earnings: NaN },
];
for (const [index, member] of malformedHistoryMembers.entries()) {
  Deno.test(`assignment history: malformed member ${index} fails before matching`, async () => {
    const client = new FakeClient(() => Promise.resolve(row("accepted")));
    // Validate the whole array before using even the preceding valid row.
    client.assignmentReadData = [validHistoryRow, member];
    const response = await run(client);
    const body = await response.json();
    assert(response.status === 500 && body.success === false &&
      body.message === "Dispatch processing unavailable" && Object.keys(body).length === 2,
      "Malformed history did not return the sanitized failure contract");
    assert(client.matchingCalls === 0 && client.assignmentUpserts === 0 &&
      client.expirationWrites === 0 && client.roundCalls === 0 && client.sleeps.length === 0,
      "Malformed history reached matching, writes or polling");
    assert(client.logs.some(log => log.includes("assignment history category=invalid_response")),
      "Missing bounded failure category");
    assert(!client.lockRunning && client.cleanupFilters[0] === client.acquiredStamp,
      "Malformed history changed owned cleanup");
  });
}

for (const status of ["sent", "accepted", "rejected", "expired", "viewed", "timed_out", "cancelled", "accepted_by_user"]) {
  for (const numeric of [null, 0, "1.25", "2e0"]) {
    Deno.test(`assignment history: valid ${status} with numeric ${numeric} preserves rules`, async () => {
      const client = new FakeClient(() => Promise.resolve(row("accepted")));
      client.assignmentReadData = [{ ...validHistoryRow, assignment_status: status,
        responded_at: new Date(client.clock).toISOString(),
        last_seen_fare: numeric, estimated_earnings: numeric }];
      client.finishAfterMatching = true;
      const response = await run(client);
      assert(response.status === 200 && (await response.json()).success === true,
        "Valid history was rejected");
      const excluded = status === "sent" || status === "accepted" ||
        ((status === "rejected" || status === "expired") && Number(numeric) >= 1);
      assert(client.matchingCalls === 1 &&
        client.matchingExclusions.includes("synthetic-rider") === excluded &&
        client.assignmentUpserts === (excluded ? 0 : 1), "Exclusion or re-offer rule changed");
    });
  }
}
