import { describe, it, expect } from "vitest";
import { narrationPlan, sourceSlice, type Cast } from "./casting";
import type { Segment, Voice } from "./types";
const segment: Segment = {
  id: "s",
  text: "A 🧭 said hi.",
  kind: "paragraph",
  locator: { href: "chapter" },
};
const voice: Voice = {
  id: "v",
  name: "Clara",
  engine: "kokoro",
  kind: "preset",
  language: "en",
  created_at: "",
};
const cast: Cast = {
  characters: [{ id: "c", name: "Clara", aliases: [], voice_id: "v" }],
  assignments: [
    {
      id: "a",
      segment_id: "s",
      start_offset: 2,
      end_offset: 3,
      character_id: "c",
      confidence: 0.3,
      reviewed: true,
    },
  ],
};
describe("reviewed source casting", () => {
  it("preserves Unicode scalar offsets including supplementary characters", () => {
    expect(sourceSlice(segment.text, 2, 3)).toBe("🧭");
    expect(narrationPlan(cast, [segment], [voice], "kokoro")[0]).toMatchObject({
      start_offset: 2,
      end_offset: 3,
      voice_id: "v",
    });
  });
  it("rejects unreviewed, overlapping, and wrong-engine voices", () => {
    expect(() =>
      narrationPlan(
        { ...cast, assignments: [{ ...cast.assignments[0], reviewed: false }] },
        [segment],
        [voice],
        "kokoro",
      ),
    ).toThrow("Review");
    expect(() =>
      narrationPlan(
        {
          ...cast,
          assignments: [
            ...cast.assignments,
            { ...cast.assignments[0], id: "b" },
          ],
        },
        [segment],
        [voice],
        "kokoro",
      ),
    ).toThrow("overlap");
    expect(() => narrationPlan(cast, [segment], [voice], "qwen3")).toThrow(
      "qwen3",
    );
  });
  it("limits the plan to requested source passages", () =>
    expect(narrationPlan(cast, [], [voice], "kokoro")).toEqual([]));
});
