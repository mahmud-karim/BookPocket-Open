import { afterEach, expect, it, vi } from "vitest";
import { chooseSaveDestination, saveAsset, submitJob } from "./api";

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

it("streams an authenticated export to disk without buffering a blob", async () => {
  vi.stubGlobal("sessionStorage", { getItem: () => "test-session" });
  const chunks: Uint8Array[] = [];
  let closed = false;
  const response = new Response(
    new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2]));
        controller.enqueue(new Uint8Array([3, 4]));
        controller.close();
      },
    }),
  );
  const blob = vi.spyOn(response, "blob");
  const fetch = vi.fn(async (_path: string, options: RequestInit) => {
    expect(new Headers(options.headers).get("Authorization")).toBe(
      "Bearer test-session",
    );
    return response;
  });
  vi.stubGlobal("fetch", fetch);
  await saveAsset("/v1/assets/export", "book.m4b", {
    createWritable: async () =>
      new WritableStream({
        write(chunk) {
          chunks.push(chunk);
        },
        close() {
          closed = true;
        },
      }),
  });
  expect(Array.from(chunks.flatMap((chunk) => Array.from(chunk)))).toEqual([
    1, 2, 3, 4,
  ]);
  expect(closed).toBe(true);
  expect(blob).not.toHaveBeenCalled();
});

it("cancels a save selection without starting a download", async () => {
  vi.stubGlobal("window", {
    showSaveFilePicker: async () => {
      throw new DOMException("Cancelled", "AbortError");
    },
  });
  expect(await chooseSaveDestination("book.m4b")).toBeNull();
});

it("aborts a partial disk download when the source stream fails", async () => {
  vi.stubGlobal("sessionStorage", { getItem: () => null });
  let aborted = false;
  vi.stubGlobal(
    "fetch",
    async () =>
      new Response(
        new ReadableStream({
          start(controller) {
            controller.error(new Error("Connection interrupted"));
          },
        }),
      ),
  );
  await expect(
    saveAsset("/v1/assets/export", "book.m4b", {
      createWritable: async () =>
        new WritableStream({
          abort() {
            aborted = true;
          },
        }),
    }),
  ).rejects.toThrow("Connection interrupted");
  expect(aborted).toBe(true);
});
