import { repairCountPortionPairs } from "./index.ts";

Deno.test("repairs a missing grams_per_unit from count and total grams", () => {
  const repaired = repairCountPortionPairs({
    items: [{ count: 3, grams: 30, name: "rice cake" }],
  }) as { items: Array<Record<string, unknown>> };
  if (repaired.items[0].grams_per_unit !== 10) {
    throw new Error(
      `expected 10 grams per unit, got ${repaired.items[0].grams_per_unit}`,
    );
  }
  if (repaired.items[0].grams !== 30) {
    throw new Error("total grams should remain consistent");
  }
});

Deno.test("repairs a missing count from grams and grams_per_unit", () => {
  const repaired = repairCountPortionPairs({
    items: [{ grams: 30, grams_per_unit: 10, name: "rice cake" }],
  }) as { items: Array<Record<string, unknown>> };
  if (repaired.items[0].count !== 3) {
    throw new Error(`expected count 3, got ${repaired.items[0].count}`);
  }
});

Deno.test("keeps non-count portions free of invented unit fields", () => {
  const repaired = repairCountPortionPairs({
    items: [{ grams: 30, name: "rice" }],
  }) as { items: Array<Record<string, unknown>> };
  if ("count" in repaired.items[0] || "grams_per_unit" in repaired.items[0]) {
    throw new Error("unit fields should not be added to a non-count portion");
  }
});
