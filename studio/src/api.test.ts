import { afterEach, expect, it, vi } from "vitest";
import { submitJob } from "./api";

afterEach(() => vi.unstubAllGlobals());
it.each([false, true])(
  "reuses request and take identities after a lost response (fresh take: %s)",
  async (fresh) => {
    const values = new Map<string, string>();
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
      removeItem: (key: string) => values.delete(key),
    };
    vi.stubGlobal("localStorage", storage);
    vi.stubGlobal("sessionStorage", { getItem: () => null });
    const sent: string[] = [];
    const takes: (string | undefined)[] = [];
    let fail = true;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_path: string, options: RequestInit) => {
        sent.push(JSON.parse(String(options.body)).request_id);
        takes.push(JSON.parse(String(options.body)).take_id);
        if (fail) {
          fail = false;
          throw new TypeError("Lost response");
        }
        return new Response(JSON.stringify({ id: "same-server-job" }), {
          status: 202,
          headers: { "Content-Type": "application/json" },
        });
      }),
    );
    await expect(
      submitJob({
        request_id: "first",
        book_id: "book",
        segment_ids: ["s"],
        take_id: fresh ? "first-take" : undefined,
      }),
    ).rejects.toThrow("Lost response");
    expect(values.size).toBe(1);
    await expect(
      submitJob({
        request_id: "retry",
        book_id: "book",
        segment_ids: ["s"],
        take_id: fresh ? "second-take" : undefined,
      }),
    ).resolves.toEqual({ id: "same-server-job" });
    expect(sent).toEqual(["first", "first"]);
    expect(takes).toEqual(
      fresh ? ["first-take", "first-take"] : [undefined, undefined],
    );
    expect(values.size).toBe(0);
  },
);
