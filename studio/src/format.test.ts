import { describe, it, expect } from "vitest";
import { duration, jobProgress } from "./format";
describe("audio time and persisted queue display", () => {
  it("does not wrap multi-hour books at an hour", () => {
    expect(duration(7261)).toBe("2:01:01");
    expect(duration(59.9)).toBe("0:59");
  });
  it("handles unavailable browser duration without NaN controls", () => {
    expect(duration(Infinity)).toBe("0:00");
    expect(duration(NaN)).toBe("0:00");
  });
  it("keeps progress bounded after server reconciliation", () => {
    expect(jobProgress(2, 0)).toBe(0);
    expect(jobProgress(8, 5)).toBe(100);
    expect(jobProgress(-1, 5)).toBe(0);
  });
});
