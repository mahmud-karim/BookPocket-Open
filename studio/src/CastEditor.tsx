import { useCallback, useEffect, useState } from "react";
import {
  Check,
  LoaderCircle,
  Plus,
  Save,
  Trash2,
  Users,
  WandSparkles,
} from "lucide-react";
import { api, post } from "./api";
import { sourceSlice, type Assignment, type Cast } from "./casting";
import type { Book, Voice } from "./types";

type Analysis = {
  id: string;
  status: string;
  completed_segments: number;
  total_segments: number;
  error?: string;
};
type Analyzer = {
  configured: boolean;
  url?: string;
  model?: string;
  hosted?: boolean;
};
export function CastEditor({
  book,
  voices,
  engine,
  onChange,
  onError,
}: {
  book: Book;
  voices: Voice[];
  engine: string;
  onChange: (cast: Cast | undefined, saved: boolean) => void;
  onError: (message: string) => void;
}) {
  const [cast, setCast] = useState<Cast>();
  const [saved, setSaved] = useState(true);
  const [busy, setBusy] = useState(false);
  const [chapter, setChapter] = useState(0);
  const [character, setCharacter] = useState("narrator");
  const [analysis, setAnalysis] = useState<Analysis>();
  const [analyzer, setAnalyzer] = useState<Analyzer>();
  const [allowHosted, setAllowHosted] = useState(false);
  const [selection, setSelection] = useState<{
    segment_id: string;
    start: number;
    end: number;
  }>();
  const reload = useCallback(async () => {
    const value = await api<Cast>(`/v1/books/${book.id}/cast`);
    setCast(value);
    setSaved(true);
    onChange(value, true);
  }, [book.id, onChange]);
  useEffect(() => {
    void reload().catch((e) => onError(e.message));
    void api<Analyzer>("/v1/admin/analyzer")
      .then(setAnalyzer)
      .catch((e) => onError(e.message));
  }, [reload, onError]);
  useEffect(() => {
    if (!analysis || !["queued", "running"].includes(analysis.status)) return;
    const timer = setInterval(() => {
      void api<Analysis>(`/v1/analyses/${analysis.id}`)
        .then(async (next) => {
          setAnalysis(next);
          if (next.status === "completed") await reload();
          if (next.status === "failed")
            onError(next.error ?? "Cast analysis failed.");
        })
        .catch((e) => onError(e.message));
    }, 1800);
    return () => clearInterval(timer);
  }, [analysis?.id, analysis?.status, reload, onError]);
  function change(next: Cast) {
    setCast(next);
    setSaved(false);
    onChange(next, false);
  }
  async function save() {
    if (!cast) return;
    setBusy(true);
    try {
      const next = await api<Cast>(`/v1/books/${book.id}/cast`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(cast),
      });
      setCast(next);
      setSaved(true);
      onChange(next, true);
    } catch (e) {
      onError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function analyze() {
    setBusy(true);
    try {
      setAnalysis(
        await post<Analysis>(`/v1/books/${book.id}/analyze`, {
          allow_hosted: allowHosted,
        }),
      );
    } catch (e) {
      onError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  function capture(element: HTMLParagraphElement, segment_id: string) {
    const range = window.getSelection();
    if (!range || range.isCollapsed || range.rangeCount !== 1) return;
    const selected = range.getRangeAt(0);
    if (
      !element.contains(selected.startContainer) ||
      !element.contains(selected.endContainer)
    )
      return;
    const before = selected.cloneRange();
    before.selectNodeContents(element);
    before.setEnd(selected.startContainer, selected.startOffset);
    const start = Array.from(before.toString()).length;
    setSelection({
      segment_id,
      start,
      end: start + Array.from(selected.toString()).length,
    });
  }
  function assign() {
    if (!cast || !selection) return;
    const a: Assignment = {
      id: crypto.randomUUID(),
      segment_id: selection.segment_id,
      start_offset: selection.start,
      end_offset: selection.end,
      character_id: character,
      confidence: 1,
      reviewed: true,
    };
    if (
      cast.assignments.some(
        (old) =>
          old.segment_id === a.segment_id &&
          a.start_offset < old.end_offset &&
          old.start_offset < a.end_offset,
      )
    ) {
      onError(
        "This selection overlaps an existing cast passage. Remove or adjust that assignment first.",
      );
      return;
    }
    change({ ...cast, assignments: [...cast.assignments, a] });
    setSelection(undefined);
    window.getSelection()?.removeAllRanges();
  }
  const running = !!analysis && ["queued", "running"].includes(analysis.status);
  const available = voices.filter((v) => v.engine === engine);
  const chapterSegments = book.chapters[chapter]?.segments ?? [];
  if (!cast)
    return (
      <section className="panel">
        <p className="muted">Loading your cast…</p>
      </section>
    );
  return (
    <section className="panel cast-editor">
      <div className="section-heading">
        <div>
          <p className="eyebrow accent">THE VOICES INSIDE YOUR STORY</p>
          <h2>Your cast</h2>
          <p className="muted">
            Assign a voice to any exact passage. Unassigned text uses your
            narrator.
          </p>
        </div>
        <button
          className="secondary"
          disabled={busy || saved || running}
          onClick={() => void save()}
        >
          <Save size={15} />
          {saved ? "Saved" : "Save cast"}
        </button>
      </div>
      <div className="cast-characters">
        {cast.characters.map((c) => (
          <div className="cast-character" key={c.id}>
            <span className="character-avatar">
              <Users size={19} />
            </span>
            <label>
              <span className="sr-only">Character name</span>
              <input
                aria-label={`Name for ${c.name}`}
                value={c.name}
                maxLength={120}
                disabled={running}
                onChange={(e) =>
                  change({
                    ...cast,
                    characters: cast.characters.map((x) =>
                      x.id === c.id ? { ...x, name: e.target.value } : x,
                    ),
                  })
                }
              />
              <input
                aria-label={`Aliases for ${c.name}`}
                placeholder="Aliases, separated by commas"
                value={c.aliases.join(", ")}
                disabled={running}
                onChange={(e) =>
                  change({
                    ...cast,
                    characters: cast.characters.map((x) =>
                      x.id === c.id
                        ? {
                            ...x,
                            aliases: e.target.value
                              .split(",")
                              .map((a) => a.trim()),
                          }
                        : x,
                    ),
                  })
                }
              />
            </label>
            <select
              aria-label={`Voice for ${c.name}`}
              value={c.voice_id ?? ""}
              disabled={running}
              onChange={(e) =>
                change({
                  ...cast,
                  characters: cast.characters.map((x) =>
                    x.id === c.id
                      ? { ...x, voice_id: e.target.value || null }
                      : x,
                  ),
                })
              }
            >
              <option value="">
                {c.id === "narrator" ? "Use narrator above" : "Choose voice"}
              </option>
              {available.map((v) => (
                <option key={v.id} value={v.id}>
                  {v.name}
                </option>
              ))}
            </select>
            {c.id !== "narrator" && (
              <button
                className="icon-button"
                disabled={running}
                aria-label={`Remove ${c.name}`}
                onClick={() => {
                  if (
                    !cast.assignments.some((a) => a.character_id === c.id) ||
                    window.confirm(
                      `Remove ${c.name} and their passage assignments?`,
                    )
                  )
                    change({
                      characters: cast.characters.filter((x) => x.id !== c.id),
                      assignments: cast.assignments.filter(
                        (a) => a.character_id !== c.id,
                      ),
                    });
                }}
              >
                <Trash2 size={15} />
              </button>
            )}
          </div>
        ))}
      </div>
      <button
        className="small-button"
        disabled={running}
        onClick={() => {
          const id = crypto.randomUUID();
          change({
            ...cast,
            characters: [
              ...cast.characters,
              { id, name: "New character", aliases: [], voice_id: null },
            ],
          });
          setCharacter(id);
        }}
      >
        <Plus size={14} />
        Add character
      </button>
      <div className="analysis-controls">
        <div>
          <h3>Suggest a cast</h3>
          <p className="muted">
            {analyzer?.configured
              ? `Analyze with ${analyzer.model}. Every suggestion needs your review.`
              : "Connect an analysis model in Settings, or assign passages yourself below."}
          </p>
          {analyzer?.hosted && (
            <label className="checkbox">
              <input
                type="checkbox"
                checked={allowHosted}
                onChange={(e) => setAllowHosted(e.target.checked)}
              />
              Send this book’s text to {analyzer.url} for this analysis.
            </label>
          )}
        </div>
        <button
          className="secondary"
          disabled={
            busy ||
            running ||
            !saved ||
            !analyzer?.configured ||
            (analyzer.hosted && !allowHosted)
          }
          onClick={() => void analyze()}
        >
          {running ? (
            <LoaderCircle size={15} className="spin" />
          ) : (
            <WandSparkles size={15} />
          )}
          Analyze book
        </button>
        {running && (
          <p className="field-help">
            {analysis.completed_segments} of {analysis.total_segments} passages
            analyzed
          </p>
        )}
      </div>
      <div className="section-heading">
        <h3>Passage assignments</h3>
        <select
          aria-label="Cast chapter"
          value={chapter}
          onChange={(e) => {
            setChapter(Number(e.target.value));
            setSelection(undefined);
          }}
        >
          {book.chapters.map((c, i) => (
            <option key={c.id} value={i}>
              {c.title}
            </option>
          ))}
        </select>
      </div>
      <p className="field-help">
        Select words in the original text, or use “Whole passage”. Multiple
        speakers can share a paragraph. Remove an assignment to return that text
        to the narrator.
      </p>
      {selection && (
        <div className="cast-selection">
          <span>
            {sourceSlice(
              book.chapters
                .flatMap((c) => c.segments)
                .find((s) => s.id === selection.segment_id)?.text ?? "",
              selection.start,
              selection.end,
            )}
          </span>
          <select
            aria-label="Selected passage character"
            value={character}
            onChange={(e) => setCharacter(e.target.value)}
          >
            {cast.characters.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
          <button
            className="primary"
            disabled={
              running || !cast.characters.some((c) => c.id === character)
            }
            onClick={assign}
          >
            <Check size={15} />
            Assign voice
          </button>
        </div>
      )}
      <div className="cast-passages">
        {chapterSegments.map((s) => (
          <article key={s.id}>
            <p
              className="cast-original"
              onMouseUp={(e) => capture(e.currentTarget, s.id)}
              onKeyUp={(e) => capture(e.currentTarget, s.id)}
              tabIndex={0}
            >
              {s.text}
            </p>
            <button
              className="small-button"
              disabled={running}
              onClick={() =>
                setSelection({
                  segment_id: s.id,
                  start: 0,
                  end: Array.from(s.text).length,
                })
              }
            >
              Whole passage
            </button>
            {cast.assignments
              .filter((a) => a.segment_id === s.id)
              .sort((a, b) => a.start_offset - b.start_offset)
              .map((a) => (
                <div
                  key={a.id}
                  className={`cast-assignment ${a.reviewed ? "reviewed" : "unreviewed"}`}
                >
                  <blockquote>
                    {sourceSlice(s.text, a.start_offset, a.end_offset)}
                  </blockquote>
                  <div className="button-row">
                    <select
                      aria-label="Speaker"
                      value={a.character_id}
                      disabled={running}
                      onChange={(e) =>
                        change({
                          ...cast,
                          assignments: cast.assignments.map((x) =>
                            x.id === a.id
                              ? {
                                  ...x,
                                  character_id: e.target.value,
                                  reviewed: false,
                                }
                              : x,
                          ),
                        })
                      }
                    >
                      {cast.characters.map((c) => (
                        <option key={c.id} value={c.id}>
                          {c.name}
                        </option>
                      ))}
                    </select>
                    <label className="checkbox">
                      <input
                        type="checkbox"
                        disabled={running}
                        checked={a.reviewed}
                        onChange={(e) =>
                          change({
                            ...cast,
                            assignments: cast.assignments.map((x) =>
                              x.id === a.id
                                ? { ...x, reviewed: e.target.checked }
                                : x,
                            ),
                          })
                        }
                      />
                      {a.reviewed
                        ? "Reviewed"
                        : `Needs review · ${Math.round(a.confidence * 100)}% confidence`}
                    </label>
                    <button
                      className="icon-button"
                      disabled={running}
                      aria-label="Remove passage assignment"
                      onClick={() =>
                        change({
                          ...cast,
                          assignments: cast.assignments.filter(
                            (x) => x.id !== a.id,
                          ),
                        })
                      }
                    >
                      <Trash2 size={14} />
                    </button>
                  </div>
                </div>
              ))}
          </article>
        ))}
      </div>
    </section>
  );
}
