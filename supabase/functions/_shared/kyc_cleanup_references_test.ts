import { KycReferenceReadError, readKycReferences } from "./kyc_cleanup_references.ts";
function assert(value: unknown, message: string): asserts value { if (!value) throw new Error(message); }
const entry = new URL("../cleanup-abandoned-kyc-uploads/index.ts", import.meta.url);
const helper = new URL("./kyc_cleanup_references.ts", import.meta.url);
const source = Deno.readTextFileSync(entry);
const adapted = source.replace(/^import .* from "(?:https:|npm:)[^\n]+\n/gm, "")
  .replace('"../_shared/kyc_cleanup_references.ts"', JSON.stringify(helper.href))
  .replaceAll("Deno.env", "testEnv");
type Handler = (request: Request) => Promise<Response>;
const shim = `let client; export let capturedHandler;
export function setClient(value) { client = value; }
const serve = handler => { capturedHandler = handler; };
const createClient = () => ({ from: (...args) => client.from(...args),
  storage: { from: (...args) => client.storage.from(...args) } });
const testEnv = { get: () => 'synthetic-cleanup-key' };
`;
const module = await import(`data:application/typescript,${encodeURIComponent(shim + adapted)}`) as {
  capturedHandler: Handler; setClient(client: Fake): void;
};
const fields = ["rider_image", "aadhaar_front_image", "aadhaar_back_image", "pan_front_image", "pan_back_image",
  "license_front_image", "license_back_image", "vehicle_image", "VECHILE_RC_front_image", "VECHILE_RC_back_image"];
const emptyRow = (): Record<string, string | null> => Object.fromEntries(fields.map(field => [field, null]));
const folder = "synthetic-owner/synthetic_attempt_1";
const old = new Date(Date.now() - 10 * 86400000).toISOString();
class Fake {
  removes: string[][] = []; reads = 0; lists = 0; columns = "";
  constructor(readonly fetch: () => Promise<unknown>) {}
  storage = { from: (bucket: string) => {
    assert(bucket === "rider_kyc", "Bucket changed");
    return { list: (prefix: string) => {
      this.lists++;
      return Promise.resolve({ data: prefix === "" ? [{ id: null, name: "synthetic-owner" }] :
        prefix === "synthetic-owner" ? [{ id: null, name: "vehicles" }, { id: null, name: "synthetic_attempt_1" }] :
        [{ id: "synthetic-object", name: "rider_image_g1.jpg", created_at: old }], error: null });
    }, remove: (paths: string[]) => { this.removes.push(paths); return Promise.resolve({ error: null }); } };
  }};
  from(table: string) {
    assert(table === "rider_kyc", "Reference table changed");
    const query = { select: (columns: string) => { this.columns = columns; return query; },
      eq: (column: string, value: string) => { assert(column === "user_id" && value === "synthetic-owner", "Owner filter changed"); return query; },
      maybeSingle: () => { this.reads++; return this.fetch(); } };
    return query;
  }
}
async function run(fake: Fake, authorized = true) {
  module.setClient(fake);
  const original = console.error;
  const logs: string[] = [];
  console.error = (...values: unknown[]) => { logs.push(values.join(" ")); };
  try {
    const response = await module.capturedHandler(new Request("http://local.invalid", {
      headers: { Authorization: `Bearer ${authorized ? "synthetic-cleanup-key" : "synthetic-user"}` },
    }));
    return { response, body: await response.json(), logs };
  } finally { console.error = original; }
}
const invalid = [
  { name: "error with null data", result: { data: null, error: { message: "synthetic-private-detail" } } },
  { name: "error takes precedence over row", result: { data: emptyRow(), error: { message: "synthetic-private-detail" } } },
  { name: "empty object", result: { data: {}, error: null } },
  { name: "array instead of row", result: { data: [], error: null } },
  { name: "scalar instead of row", result: { data: false, error: null } },
  { name: "missing selected field", result: { data: { ...emptyRow(), rider_image: undefined }, error: null } },
  { name: "invalid selected value", result: { data: { ...emptyRow(), rider_image: 9 }, error: null } },
  { name: "missing error metadata", result: { data: null } },
];
for (const failure of invalid) {
  Deno.test(`actual cleanup handler: ${failure.name} cannot authorize deletion`, async () => {
    const fake = new Fake(() => Promise.resolve(failure.result));
    const result = await run(fake);
    assert(result.response.status === 200 && fake.removes.length === 0, "Failed reference check deleted objects");
    assert(fake.reads === 1 && fake.columns.split(",").join() === fields.join(), "Reference projection changed");
    assert(!result.logs.join().includes("synthetic-private-detail"), "Reference error leaked");
    assert(result.logs.some(log => log.includes("Reference check skipped category=")), "Bounded category missing");
    assert(result.body.deletedObjects === 0 && result.body.prunedObsoleteVersions === 0, "Failure reported deletion");
  });
}
Deno.test("actual handler: rejected timeout cannot authorize deletion", async () => {
  let reject!: (error: Error) => void;
  let started!: () => void;
  const began = new Promise<void>(resolve => { started = resolve; });
  const pending = new Promise<unknown>((_, failure) => { reject = failure; });
  const fake = new Fake(() => { started(); return pending; });
  const running = run(fake);
  await began;
  assert(fake.removes.length === 0, "Pending reference lookup deleted objects");
  reject(new Error("synthetic-private-timeout"));
  const result = await running;
  assert(fake.removes.length === 0 && !result.logs.join().includes("synthetic-private-timeout"), "Timeout leaked or deleted");
});
Deno.test("actual handler: valid absent row keeps legitimate old-folder cleanup", async () => {
  const fake = new Fake(() => Promise.resolve({ data: null, error: null }));
  const result = await run(fake);
  assert(fake.removes.length === 1 && fake.removes[0][0] === `${folder}/rider_image_g1.jpg`, "Valid absence behavior changed");
  assert(result.body.deletedObjects === 1 && fake.lists === 3, "Vehicle subtree was scanned or counts changed");
});
Deno.test("actual handler: referenced object survives; valid null fields permit existing pruning", async () => {
  const row = emptyRow(); row.rider_image = `${folder}/rider_image_g1.jpg`;
  const fake = new Fake(() => Promise.resolve({ data: row, error: null }));
  await run(fake); assert(fake.removes.length === 0, "Referenced object deleted");
  row.rider_image = `${folder}/rider_image_g2.jpg`;
  const pruning = new Fake(() => Promise.resolve({ data: row, error: null }));
  await run(pruning); assert(pruning.removes.length === 1, "Valid obsolete generation no longer pruned");
});
Deno.test("actual handler: ordinary session denied before Storage/DB calls", async () => {
  const fake = new Fake(() => Promise.resolve({ data: null, error: null }));
  const result = await run(fake, false);
  assert(result.response.status === 403 && fake.reads === 0 && fake.lists === 0 && fake.removes.length === 0, "Authorization changed");
});
Deno.test("helper throws classified failures and accepts nullable/legacy string values", async () => {
  let error: unknown;
  try { await readKycReferences(() => Promise.reject(new Error("private")), fields); } catch (value) { error = value; }
  assert(error instanceof KycReferenceReadError && error.category === "query_exception", "Thrown query misclassified");
  const row = emptyRow(); row.rider_image = "https://synthetic.invalid/legacy.jpg";
  const values = await readKycReferences(() => Promise.resolve({ data: row, error: null }), fields);
  assert(values.length === 1 && values[0] === row.rider_image, "Legacy string changed");
});
