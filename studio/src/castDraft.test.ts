import { describe, it, expect } from "vitest";
import {
  CastDraft,
  mergeCastDraft,
  sameCast,
  type CastAnalysis,
  type CastService,
} from "./castDraft";
import { sourceSlice, type Assignment, type Cast } from "./casting";
import { APIError } from "./api";

const character = {
  id: "mira",
  name: "Mira",
  aliases: ["Captain"],
  voice_id: "v1",
};
const row = (
  id: string,
  start: number,
  end: number,
  extra: Partial<Assignment> = {},
): Assignment => ({
  id,
  segment_id: "s",
  start_offset: start,
  end_offset: end,
  character_id: "mira",
  confidence: 0.6,
  reviewed: false,
  ...extra,
});
const cast = (...assignments: Assignment[]): Cast => ({
  characters: [{ ...character, aliases: [...character.aliases] }],
  assignments,
});
const empty: Cast = { characters: [], assignments: [] };
const analysis: CastAnalysis = {
  id: "analysis",
  status: "running",
  completed_segments: 0,
  total_segments: 1,
};
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
function service(value: Cast): CastService {
  return {
    fetch: async () => value,
    save: async (next) => next,
    canRecoverAnalysis: async () => true,
    analyze: async () => analysis,
    poll: async () => ({ ...analysis, status: "completed" }),
  };
}

describe("cast draft three-way merge", () => {
  it("retains a moved unreviewed human assignment when the server drops its character", () => {
    const base = cast(row("a", 0, 3));
    const local = cast(row("a", 5, 8));
    expect(mergeCastDraft(base, local, empty)).toEqual(local);
  });
  it("rejects invalid or overlapping arrivals without changing the controller draft", async () => {
    const draft = new CastDraft([
      {
        id: "s",
        text: "A 🧭 says hi.",
        kind: "paragraph",
        locator: { href: "chapter" },
      },
    ]);
    await draft.load(service(cast(row("a", 2, 3))));
    const before = draft.value;
    for (const bad of [
      cast(row("bad", 0, 100)),
      cast(row("bad", 0, 2, { segment_id: "foreign" })),
      cast(row("a", 1, 3), row("b", 2, 4)),
    ]) {
      await expect(draft.load(service(bad))).rejects.toThrow(
        "invalid source ranges",
      );
      expect(draft.value).toBe(before);
    }
  });
  it("preserves edited fields independently and accepts untouched remote fields", () => {
    const base = cast();
    const local = {
      ...base,
      characters: [{ ...character, aliases: [], voice_id: "v2" }],
    };
    const remote = {
      ...base,
      characters: [
        { ...character, name: "Mira Vale", aliases: ["Captain", "Pilot"] },
      ],
    };
    expect(mergeCastDraft(base, local, remote).characters[0]).toEqual({
      ...character,
      name: "Mira Vale",
      aliases: [],
      voice_id: "v2",
    });
    expect(base.characters[0].aliases).toEqual(["Captain"]);
  });
  it("keeps a manual emoji span and suppresses nested proposals with regenerated IDs", () => {
    const text = "A 🧭 said hello.";
    const local = cast(row("manual", 2, 3, { reviewed: true }));
    const merged = mergeCastDraft(
      cast(),
      local,
      cast(row("model", 0, 8), row("other", 9, 14)),
    );
    expect(merged.assignments.map((a) => a.id)).toEqual(["other", "manual"]);
    expect(
      sourceSlice(
        text,
        merged.assignments[1].start_offset,
        merged.assignments[1].end_offset,
      ),
    ).toBe("🧭");
  });
  it("blocks deleted ranges and both positions of a moved unreviewed passage", () => {
    const base = cast(row("deleted", 0, 3), row("moved", 4, 7));
    const local = cast(row("moved", 10, 13));
    const remote = cast(
      row("deleted-new-id", 0, 3),
      row("old-place", 4, 7),
      row("new-place", 11, 12),
      row("elsewhere", 14, 18),
    );
    expect(mergeCastDraft(base, local, remote).assignments).toEqual([
      remote.assignments[3],
      local.assignments[0],
    ]);
  });
  it("keeps new characters, drops deleted characters and their new proposals", () => {
    const base = cast(row("a", 0, 3));
    const local = {
      characters: [{ id: "new", name: "Ada", aliases: [], voice_id: null }],
      assignments: [],
    };
    const merged = mergeCastDraft(base, local, cast(row("new-model-id", 4, 7)));
    expect(merged).toEqual(local);
  });
  it("distinguishes explicit clear-all from an initially empty cast", () => {
    expect(mergeCastDraft(cast(), empty, cast(row("a", 0, 2)))).toEqual(empty);
    expect(mergeCastDraft(empty, empty, cast(row("a", 0, 2)))).toEqual(
      cast(row("a", 0, 2)),
    );
  });
  it("ignores record order for dirty state but detects alias removal and review changes", () => {
    const a = cast(row("a", 0, 2), row("b", 4, 6));
    expect(
      sameCast(a, { ...a, assignments: [...a.assignments].reverse() }),
    ).toBe(true);
    expect(
      sameCast(a, { ...a, characters: [{ ...character, aliases: [] }] }),
    ).toBe(false);
    expect(
      sameCast(a, cast(row("a", 0, 2, { reviewed: true }), a.assignments[1])),
    ).toBe(false);
  });
});

describe("production cast controller with delayed services", () => {
  it("recovers an accepted submission after a lost response with the original ID, consent and merge base", async () => {
    const draft = new CastDraft();
    const base = cast(row("deleted", 0, 3));
    await draft.load(service(base));
    const requests: { id: string; consent: boolean }[] = [];
    let saves = 0;
    const transport: CastService = {
      ...service(base),
      save: async (value) => {
        saves++;
        return value;
      },
      analyze: async (consent, id) => {
        requests.push({ id, consent });
        if (requests.length === 1)
          throw new TypeError("Confirmation lost after acceptance");
        return { ...analysis, status: "completed" };
      },
      fetch: async () => cast(row("replacement", 0, 3), row("new", 10, 13)),
    };
    await expect(draft.analyze(transport, true)).rejects.toThrow(
      "Confirmation lost",
    );
    expect(draft.busy).toBe(true);
    expect(draft.canRetryConfirmation).toBe(true);
    draft.change({
      ...base,
      characters: [{ ...character, name: "My Mira", aliases: [] }],
      assignments: [],
    });
    await draft.save(transport);
    await draft.load(transport);
    await draft.analyze(transport, false);
    expect(saves).toBe(0);
    expect(requests).toHaveLength(1);
    await draft.retryConfirmation(transport);
    expect(requests[1]).toEqual(requests[0]);
    expect(requests[0].consent).toBe(true);
    expect(requests[0].id).toMatch(/^[0-9a-f-]{36}$/);
    expect(draft.value?.characters[0]).toMatchObject({
      name: "My Mira",
      aliases: [],
    });
    expect(draft.value?.assignments.map((a) => a.id)).toEqual(["new"]);
    expect(draft.busy).toBe(false);
    expect(draft.canRetryConfirmation).toBe(false);
    expect(draft.saved).toBe(false);
    await draft.save(service(draft.value!));
    await draft.analyze(transport, false);
    expect(requests[2].id).not.toBe(requests[0].id);
    expect(requests[2].consent).toBe(false);
  });
  it("blocks older companions before submitting, without trapping the draft", async () => {
    const draft = new CastDraft();
    await draft.load(service(cast()));
    let starts = 0;
    await expect(
      draft.analyze(
        {
          ...service(cast()),
          canRecoverAnalysis: async () => false,
          analyze: async () => {
            starts++;
            return analysis;
          },
        },
        false,
      ),
    ).rejects.toThrow("Update the PC companion");
    expect(starts).toBe(0);
    expect(draft.busy).toBe(false);
    expect(draft.canRetryConfirmation).toBe(false);
  });
  it("preserves edits made during capability checking against the last saved cast", async () => {
    const draft = new CastDraft();
    const base = cast(row("a", 0, 3));
    await draft.load(service(base));
    const capability = deferred<boolean>();
    const starting = draft.analyze(
      { ...service(base), canRecoverAnalysis: () => capability.promise },
      false,
    );
    draft.change({ ...base, assignments: [] });
    capability.resolve(true);
    await starting;
    await draft.poll(service(cast(row("returned", 0, 3), row("new", 4, 7))));
    expect(draft.value?.assignments.map((a) => a.id)).toEqual(["new"]);
  });
  it("releases an explicitly rejected initial request but retains uncertain recovery after errors", async () => {
    const draft = new CastDraft();
    await draft.load(service(cast()));
    const rejected = {
      ...service(cast()),
      analyze: async () => {
        throw new APIError("Another analysis is running", 409);
      },
    };
    await expect(draft.analyze(rejected, false)).rejects.toThrow(
      "Another analysis",
    );
    expect(draft.busy).toBe(false);
    expect(draft.canRetryConfirmation).toBe(false);
    const ids: string[] = [];
    const lost = {
      ...service(cast()),
      analyze: async (_consent: boolean, id: string) => {
        ids.push(id);
        throw new TypeError("Offline");
      },
    };
    await expect(draft.analyze(lost, false)).rejects.toThrow("Offline");
    await expect(draft.retryConfirmation(rejected)).rejects.toThrow(
      "Another analysis",
    );
    await expect(
      draft.retryConfirmation({
        ...lost,
        canRecoverAnalysis: async () => false,
      }),
    ).rejects.toThrow("Update the PC companion");
    expect(draft.busy).toBe(true);
    expect(draft.canRetryConfirmation).toBe(true);
    await expect(draft.retryConfirmation(lost)).rejects.toThrow("Offline");
    expect(ids[1]).toBe(ids[0]);
  });
  it("allows only one confirmation recovery in flight", async () => {
    const draft = new CastDraft();
    await draft.load(service(cast()));
    await expect(
      draft.analyze(
        {
          ...service(cast()),
          analyze: async () => {
            throw new TypeError("Offline");
          },
        },
        false,
      ),
    ).rejects.toThrow("Offline");
    const response = deferred<CastAnalysis>();
    let requests = 0;
    const transport = {
      ...service(cast()),
      analyze: async () => {
        requests++;
        return response.promise;
      },
    };
    const recovering = draft.retryConfirmation(transport);
    await Promise.resolve();
    await draft.retryConfirmation(transport);
    expect(requests).toBe(1);
    expect(draft.canRetryConfirmation).toBe(false);
    response.resolve(analysis);
    await recovering;
    expect(draft.analysis?.id).toBe(analysis.id);
    expect(draft.busy).toBe(true);
  });
  it("does not label edits made during a delayed save as saved", async () => {
    const draft = new CastDraft();
    await draft.load(service(cast()));
    draft.change({
      ...cast(),
      characters: [{ ...character, name: "First edit" }],
    });
    const response = deferred<Cast>();
    let payload!: Cast;
    const saving = draft.save({
      ...service(cast()),
      save: (value) => {
        payload = value;
        return response.promise;
      },
    });
    draft.change({
      ...cast(),
      characters: [{ ...character, name: "Second edit", aliases: [] }],
    });
    expect(payload.characters[0].name).toBe("First edit");
    response.resolve(payload);
    await saving;
    expect(draft.value?.characters[0]).toMatchObject({
      name: "Second edit",
      aliases: [],
    });
    expect(draft.saved).toBe(false);
    await draft.save(service(cast()));
    expect(draft.saved).toBe(true);
  });
  it("preserves drafts made during delayed analysis and final fetch, with one poll at a time", async () => {
    const draft = new CastDraft();
    const base = cast(row("deleted", 0, 3));
    await draft.load(service(base));
    const start = deferred<CastAnalysis>();
    const fetch = deferred<Cast>();
    const poll = deferred<CastAnalysis>();
    let polls = 0;
    let saves = 0;
    const transport = {
      ...service(base),
      analyze: () => start.promise,
      poll: () => {
        polls++;
        return poll.promise;
      },
      fetch: () => fetch.promise,
      save: async (value: Cast) => {
        saves++;
        return value;
      },
    };
    const starting = draft.analyze(transport, false);
    draft.change({
      ...base,
      characters: [{ ...character, aliases: [], name: "My Mira" }],
      assignments: [],
    });
    start.resolve(analysis);
    await starting;
    const polling = draft.poll(transport);
    await draft.poll(transport);
    expect(polls).toBe(1);
    poll.resolve({ ...analysis, status: "completed" });
    await Promise.resolve();
    expect(draft.busy).toBe(true);
    await draft.save(transport);
    expect(saves).toBe(0);
    draft.change({
      ...draft.value!,
      assignments: [row("manual", 4, 7, { reviewed: true })],
    });
    fetch.resolve(
      cast(row("resurrected", 0, 3), row("nested", 5, 6), row("new", 10, 13)),
    );
    await polling;
    expect(draft.value?.characters[0]).toMatchObject({
      name: "My Mira",
      aliases: [],
    });
    expect(draft.value?.assignments.map((a) => a.id)).toEqual([
      "new",
      "manual",
    ]);
    expect(draft.saved).toBe(false);
    expect(draft.busy).toBe(false);
    expect(draft.analysis?.status).toBe("completed");
  });
  it("retains edits on editor reopen and prevents late responses crossing books", async () => {
    const first = new CastDraft();
    const second = new CastDraft();
    await first.load(service(cast()));
    first.change({
      ...cast(),
      characters: [{ ...character, name: "Unsaved name" }],
    });
    const arrival = deferred<Cast>();
    const reading = first.load({
      ...service(cast()),
      fetch: () => arrival.promise,
    });
    await second.load(service(empty));
    first.change({
      ...first.value!,
      characters: [{ ...character, name: "Latest edit" }],
    });
    arrival.resolve(cast());
    await reading;
    expect(first.value?.characters[0].name).toBe("Latest edit");
    expect(first.saved).toBe(false);
    expect(second.value).toEqual(empty);
  });
  it("keeps drafts on failed saves and retries a failed final fetch", async () => {
    const draft = new CastDraft();
    await draft.load(service(cast()));
    draft.change({
      ...cast(),
      assignments: [row("manual", 0, 2, { reviewed: true })],
    });
    await expect(
      draft.save({
        ...service(cast()),
        save: async () => {
          throw new Error("Offline");
        },
      }),
    ).rejects.toThrow("Offline");
    expect(draft.saved).toBe(false);
    expect(draft.busy).toBe(false);
    await draft.save(service(cast()));
    await draft.analyze(service(cast()), false);
    await expect(
      draft.poll({
        ...service(cast()),
        fetch: async () => {
          throw new Error("Offline");
        },
      }),
    ).rejects.toThrow("Offline");
    expect(draft.busy).toBe(true);
    expect(draft.value?.assignments[0].id).toBe("manual");
    await draft.poll(service(cast(row("model", 4, 6))));
    expect(draft.busy).toBe(false);
    expect(draft.value?.assignments.map((a) => a.id)).toEqual([
      "model",
      "manual",
    ]);
  });
});
