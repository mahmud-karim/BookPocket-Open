import { useEffect, useState } from "react";
import { ArrowDownToLine, Play } from "lucide-react";
import { api, chooseSaveDestination, saveAsset } from "./api";
import { duration } from "./format";
import type { Asset, Book } from "./types";
type LegacyRecording = {
  id: string;
  book_id: string;
  title: string;
  asset: Asset;
  mapping: "text_match_without_timings" | "unmapped";
  source_text?: string;
};
export function LegacyShelf({
  books,
  onPlay,
  onError,
}: {
  books: Book[];
  onPlay: (book: Book, assets: Asset[]) => void;
  onError: (message: string) => void;
}) {
  const [recordings, setRecordings] = useState<LegacyRecording[]>([]);
  useEffect(() => {
    let active = true;
    void api<{ recordings: LegacyRecording[] }>("/v1/legacy-recordings")
      .then((value) => {
        if (active) setRecordings(value.recordings);
      })
      .catch((e) => {
        if (active) onError(e.message);
      });
    return () => {
      active = false;
    };
  }, [onError]);
  if (!recordings.length) return null;
  return (
    <section className="legacy-shelf">
      <div className="section-heading">
        <div>
          <h2>Legacy recordings</h2>
          <p className="muted">
            Audio carried over from your old library. Original page positions
            are retained as reference; synchronized highlighting is unavailable.
          </p>
        </div>
      </div>
      <div className="recordings">
        {recordings.map((recording) => {
          const book = books.find((b) => b.id === recording.book_id);
          return (
            <article key={recording.id} className="panel">
              <div className="section-heading">
                <div>
                  <h3>{recording.title}</h3>
                  <p className="muted">
                    {book?.title ?? "Imported audio"} ·{" "}
                    {duration(recording.asset.duration)}
                  </p>
                </div>
                <span className="status-pill">
                  {recording.mapping === "text_match_without_timings"
                    ? "Text matched · no timing"
                    : "Unmatched audio"}
                </span>
              </div>
              {recording.source_text && (
                <p className="legacy-quote">{recording.source_text}</p>
              )}
              <div className="button-row">
                {book && (
                  <button
                    className="secondary"
                    onClick={() => onPlay(book, [recording.asset])}
                  >
                    <Play size={15} />
                    Listen
                  </button>
                )}
                <button
                  className="secondary"
                  onClick={() => {
                    void (async () => {
                      const destination = await chooseSaveDestination(
                        "legacy-recording.wav",
                      );
                      if (destination === null) return;
                      await saveAsset(
                        recording.asset.url,
                        "legacy-recording.wav",
                        destination,
                      );
                    })().catch((e) => onError(e.message));
                  }}
                >
                  <ArrowDownToLine size={15} />
                  Download audio
                </button>
              </div>
            </article>
          );
        })}
      </div>
    </section>
  );
}
