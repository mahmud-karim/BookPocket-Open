import type { Segment, Voice } from "./types";
export type Character = {
  id: string;
  name: string;
  aliases: string[];
  voice_id: string | null;
};
export type Assignment = {
  id: string;
  segment_id: string;
  start_offset: number;
  end_offset: number;
  character_id: string;
  confidence: number;
  reviewed: boolean;
};
export type Cast = { characters: Character[]; assignments: Assignment[] };
export type NarrationSpan = {
  segment_id: string;
  start_offset: number;
  end_offset: number;
  voice_id: string;
};
export const sourceSlice = (text: string, start: number, end: number) =>
  Array.from(text).slice(start, end).join("");

export function narrationPlan(
  cast: Cast,
  segments: Segment[],
  voices: Voice[],
  engine: string,
): NarrationSpan[] {
  const plan: NarrationSpan[] = [];
  for (const segment of segments) {
    const assignments = cast.assignments
      .filter((a) => a.segment_id === segment.id)
      .sort((a, b) => a.start_offset - b.start_offset);
    let end = 0;
    for (const a of assignments) {
      if (!a.reviewed)
        throw new Error(
          "Review each cast suggestion in this selection before generating.",
        );
      if (
        a.start_offset < end ||
        a.start_offset >= a.end_offset ||
        a.end_offset > Array.from(segment.text).length
      )
        throw new Error(
          "A cast passage overlaps or is outside the original text.",
        );
      const character = cast.characters.find((c) => c.id === a.character_id);
      if (!character)
        throw new Error("A passage refers to a missing character.");
      if (character.id === "narrator" && !character.voice_id) {
        end = a.end_offset;
        continue;
      }
      const voice = voices.find(
        (v) => v.id === character.voice_id && v.engine === engine,
      );
      if (!voice)
        throw new Error(`Choose a ${engine} voice for ${character.name}.`);
      plan.push({
        segment_id: segment.id,
        start_offset: a.start_offset,
        end_offset: a.end_offset,
        voice_id: voice.id,
      });
      end = a.end_offset;
    }
  }
  return plan;
}
