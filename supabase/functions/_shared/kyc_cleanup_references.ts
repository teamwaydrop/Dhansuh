export class KycReferenceReadError extends Error {
  constructor(readonly category: "query_error" | "query_exception" | "invalid_response") {
    super("KYC references unavailable");
  }
}

/** A successful maybeSingle null is absence; errors and incomplete rows are not. */
export async function readKycReferences(
  fetch: () => PromiseLike<unknown>, fields: readonly string[],
): Promise<string[]> {
  let result: unknown;
  try { result = await fetch(); } catch { throw new KycReferenceReadError("query_exception"); }
  if (result === null || typeof result !== "object" || Array.isArray(result) ||
      !Object.hasOwn(result, "data") || !Object.hasOwn(result, "error")) {
    throw new KycReferenceReadError("invalid_response");
  }
  const response = result as Record<string, unknown>;
  if (response.error !== null) throw new KycReferenceReadError("query_error");
  if (response.data === null) return [];
  if (typeof response.data !== "object" || Array.isArray(response.data)) {
    throw new KycReferenceReadError("invalid_response");
  }
  const row = response.data as Record<string, unknown>;
  const references: string[] = [];
  for (const field of fields) {
    if (!Object.hasOwn(row, field) || (row[field] !== null && typeof row[field] !== "string")) {
      throw new KycReferenceReadError("invalid_response");
    }
    if (typeof row[field] === "string") references.push(row[field]);
  }
  return references;
}
