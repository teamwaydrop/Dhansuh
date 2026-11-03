// Supabase's ungenerated relation types may infer arrays for to-one embeds.
// Preserve object/null responses and refuse ambiguous multi-row relations.
export function singleRelation<T>(value: T | T[] | null): T | null {
  if (Array.isArray(value)) return value.length === 1 ? value[0] : null;
  return value;
}
