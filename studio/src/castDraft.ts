import type { Assignment, Cast, Character } from "./casting";
import type { Segment } from "./types";

const empty = (): Cast => ({ characters: [], assignments: [] });
const clone = (cast: Cast): Cast => ({
  characters: cast.characters.map((c) => ({ ...c, aliases: [...c.aliases] })),
  assignments: cast.assignments.map((a) => ({ ...a })),
});
const sameAliases = (a: string[], b: string[]) =>
  a.length === b.length && a.every((value, i) => value === b[i]);
const sameCharacter = (a: Character, b: Character) =>
  a.id === b.id &&
  a.name === b.name &&
  a.voice_id === b.voice_id &&
  sameAliases(a.aliases, b.aliases);
const sameAssignment = (a: Assignment, b: Assignment) =>
  a.id === b.id &&
  a.segment_id === b.segment_id &&
  a.start_offset === b.start_offset &&
  a.end_offset === b.end_offset &&
  a.character_id === b.character_id &&
  a.confidence === b.confidence &&
  a.reviewed === b.reviewed;
const overlaps = (a: Assignment, b: Assignment) =>
  a.segment_id === b.segment_id &&
  a.start_offset < b.end_offset &&
  b.start_offset < a.end_offset;

export function sameCast(a: Cast, b: Cast): boolean {
  return (
    a.characters.length === b.characters.length &&
    a.assignments.length === b.assignments.length &&
    a.characters.every((c) => {
      const other = b.characters.find((x) => x.id === c.id);
      return !!other && sameCharacter(c, other);
    }) &&
    a.assignments.every((item) => {
      const other = b.assignments.find((x) => x.id === item.id);
      return !!other && sameAssignment(item, other);
    })
  );
}

/** Merge server suggestions against the saved snapshot and the latest human draft.
 * Range tombstones survive model-generated assignment IDs; offsets remain scalars.
 */
export function mergeCastDraft(
  base: Cast,
  local: Cast,
  incoming: Cast,
  segments?: Segment[],
): Cast {
  if (
    !local.characters.length &&
    !local.assignments.length &&
    (base.characters.length || base.assignments.length)
  )
    return empty();
  const deletedCharacters = new Set(
    base.characters
      .filter((c) => !local.characters.some((x) => x.id === c.id))
      .map((c) => c.id),
  );
  const protectedAssignments = local.assignments.filter((a) => {
    const old = base.assignments.find((x) => x.id === a.id);
    return a.reviewed || !old || !sameAssignment(a, old);
  });
  const characters = incoming.characters
    .filter((c) => !deletedCharacters.has(c.id))
    .map((remote) => {
      const current = local.characters.find((c) => c.id === remote.id);
      const old = base.characters.find((c) => c.id === remote.id);
      if (!current) return { ...remote, aliases: [...remote.aliases] };
      if (!old) return { ...current, aliases: [...current.aliases] };
      return {
        ...remote,
        name: current.name !== old.name ? current.name : remote.name,
        voice_id:
          current.voice_id !== old.voice_id
            ? current.voice_id
            : remote.voice_id,
        aliases: [
          ...(!sameAliases(current.aliases, old.aliases)
            ? current.aliases
            : remote.aliases),
        ],
      };
    });
  for (const current of local.characters) {
    if (!characters.some((c) => c.id === current.id)) {
      const old = base.characters.find((c) => c.id === current.id);
      if (
        !old ||
        !sameCharacter(current, old) ||
        protectedAssignments.some((a) => a.character_id === current.id)
      )
        characters.push({ ...current, aliases: [...current.aliases] });
    }
  }
  const knownCharacters = new Set(characters.map((c) => c.id));
  const exclusions = base.assignments.filter((old) => {
    const current = local.assignments.find((a) => a.id === old.id);
    return !current || !sameAssignment(current, old);
  });
  const assignments = incoming.assignments
    .filter(
      (a) =>
        knownCharacters.has(a.character_id) &&
        !protectedAssignments.some((p) => p.id === a.id || overlaps(p, a)) &&
        !exclusions.some((p) => p.id === a.id || overlaps(p, a)),
    )
    .map((a) => ({ ...a }));
  assignments.push(
    ...protectedAssignments
      .filter((a) => knownCharacters.has(a.character_id))
      .map((a) => ({ ...a })),
  );
  const merged = { characters, assignments };
  if (
    knownCharacters.size !== characters.length ||
    new Set(assignments.map((a) => a.id)).size !== assignments.length ||
    assignments.some(
      (a, i) =>
        !Number.isInteger(a.start_offset) ||
        !Number.isInteger(a.end_offset) ||
        a.start_offset < 0 ||
        a.start_offset >= a.end_offset ||
        !Number.isFinite(a.confidence) ||
        a.confidence < 0 ||
        a.confidence > 1 ||
        assignments.slice(0, i).some((b) => overlaps(a, b)) ||
        (segments &&
          !segments.some(
            (s) =>
              s.id === a.segment_id &&
              a.end_offset <= Array.from(s.text).length,
          )),
    )
  )
    throw new Error(
      "The returned cast contains conflicting or invalid source ranges. Your local edits have been kept. Refresh the cast or review the analysis on your PC.",
    );
  return merged;
}

export type CastAnalysis = {
  id: string;
  status: string;
  completed_segments: number;
  total_segments: number;
  error?: string;
  warnings?: string[];
};
export type CastService = {
  fetch: () => Promise<Cast>;
  save: (cast: Cast) => Promise<Cast>;
  analyze: (allowHosted: boolean) => Promise<CastAnalysis>;
  poll: (id: string) => Promise<CastAnalysis>;
};

/** Per-book, memory-only controller shared by the UI and controlled async tests. */
export class CastDraft {
  constructor(private readonly segments?: Segment[]) {}
  value?: Cast;
  saved = true;
  busy = false;
  analysis?: CastAnalysis;
  private base = empty();
  private analysisBase?: Cast;
  private listeners = new Set<() => void>();
  private reading = false;
  private polling = false;
  get loading() {
    return this.reading;
  }
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
  private emit() {
    this.listeners.forEach((listener) => listener());
  }
  private receive(base: Cast, remote: Cast) {
    this.value = mergeCastDraft(
      base,
      this.value ?? base,
      remote,
      this.segments,
    );
    this.base = clone(remote);
    this.saved = sameCast(this.value, this.base);
    this.emit();
  }
  change(next: Cast) {
    this.value = clone(next);
    this.saved = sameCast(this.value, this.base);
    this.emit();
  }
  async load(service: CastService) {
    if (this.reading || this.busy) return;
    this.reading = true;
    this.emit();
    const base = clone(this.base);
    try {
      this.receive(base, await service.fetch());
    } finally {
      this.reading = false;
      this.emit();
    }
  }
  async save(service: CastService) {
    if (!this.value || this.busy || this.reading) return;
    this.busy = true;
    this.emit();
    const snapshot = clone(this.value);
    try {
      this.receive(snapshot, await service.save(clone(snapshot)));
    } finally {
      this.busy = false;
      this.emit();
    }
  }
  async analyze(service: CastService, allowHosted: boolean) {
    if (!this.value || !this.saved || this.busy || this.reading) return;
    this.busy = true;
    this.analysisBase = clone(this.value);
    this.analysis = undefined;
    this.emit();
    try {
      this.analysis = await service.analyze(allowHosted);
    } catch (error) {
      this.busy = false;
      this.analysisBase = undefined;
      this.emit();
      throw error;
    }
    try {
      // Keep Save disabled through final fetch, even if the start response is terminal.
      if (!["queued", "running"].includes(this.analysis.status))
        await this.finish(service, this.analysis);
    } finally {
      this.emit();
    }
  }
  private async finish(service: CastService, next: CastAnalysis) {
    if (next.status === "completed")
      this.receive(this.analysisBase ?? this.base, await service.fetch());
    this.analysis = next;
    this.analysisBase = undefined;
    this.busy = false;
    if (next.status === "failed")
      throw new Error(next.error ?? "Cast analysis failed.");
  }
  async poll(service: CastService) {
    if (!this.analysis || !this.analysisBase || this.polling) return;
    this.polling = true;
    const id = this.analysis.id;
    try {
      const next = await service.poll(id);
      if (next.id !== id)
        throw new Error("Analysis returned an unexpected identifier.");
      if (["queued", "running"].includes(next.status)) this.analysis = next;
      else await this.finish(service, next);
    } finally {
      this.polling = false;
      this.emit();
    }
  }
}
