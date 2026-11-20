// The server's chat feature list (egorsmkv.github.io/features) as values
// (pure, unit-tested; server_features.ts applies them).
import type { FeatureKey } from "./types.ts";

export const FEATURE_KEYS: FeatureKey[] = [
  "reactions",
  "replies",
  "typing",
  "editing",
  "redaction",
  "link_previews",
];

/** The features named in a features capability value ("none" for none). */
export function parseFeatures(value: string): Record<FeatureKey, boolean> {
  const on = new Set(value === "none" ? [] : value.split(",").filter(Boolean));
  return Object.fromEntries(FEATURE_KEYS.map((k) => [k, on.has(k)])) as Record<
    FeatureKey,
    boolean
  >;
}

/** Keys whose value differs between `before` and `after`. */
export function changedFeatures(
  before: Record<FeatureKey, boolean>,
  after: Partial<Record<FeatureKey, boolean>>,
): FeatureKey[] {
  return FEATURE_KEYS.filter((k) => k in after && after[k] !== before[k]);
}
