import { singleRelation } from "./single_relation.ts";

Deno.test("single relation preserves object and null and handles inferred arrays", () => {
  const row = { id: "synthetic" };
  if (singleRelation(row) !== row || singleRelation([row]) !== row ||
      singleRelation(null) !== null || singleRelation([]) !== null ||
      singleRelation([row, row]) !== null) {
    throw new Error("Relation cardinality validation failed");
  }
});
