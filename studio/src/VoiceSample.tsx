import { useEffect, useRef, useState } from "react";
import { Play, Volume2 } from "lucide-react";
import { mediaURL } from "./api";

export function VoiceSampleInput() {
  const [file, setFile] = useState<File>();
  const [src, setSrc] = useState("");
  const [duration, setDuration] = useState(0);
  const [start, setStart] = useState(0);
  const [end, setEnd] = useState(0);
  const [error, setError] = useState("");
  const audio = useRef<HTMLAudioElement>(null);
  useEffect(() => {
    if (!file) return;
    const url = URL.createObjectURL(file);
    setSrc(url);
    setStart(0);
    setEnd(0);
    setError("");
    return () => URL.revokeObjectURL(url);
  }, [file]);
  const invalid =
    !!file &&
    (end - start < 3 || end - start > 120 || end > duration || start < 0);
  return (
    <>
      <label>
        Reference recording
        <input
          name="reference"
          type="file"
          required
          accept="audio/*"
          onChange={(e) => {
            setDuration(0);
            setFile(e.target.files?.[0]);
          }}
        />
      </label>
      {src && (
        <div className="sample-editor">
          <audio
            ref={audio}
            src={src}
            controls
            onLoadedMetadata={() => {
              const n = audio.current?.duration ?? 0;
              setDuration(n);
              setEnd(Math.min(120, n));
            }}
            onTimeUpdate={() => {
              if (audio.current && audio.current.currentTime >= end)
                audio.current.pause();
            }}
            onError={() =>
              setError(
                "This recording cannot be previewed. Choose a WAV, MP3, or M4A file supported by your browser.",
              )
            }
          />
          <div className="sample-trim">
            <label>
              Start, seconds
              <input
                name="trim_start"
                type="number"
                min="0"
                max={Math.max(0, end - 3)}
                step="0.1"
                required
                value={start}
                onChange={(e) => setStart(Number(e.target.value))}
              />
            </label>
            <label>
              End, seconds
              <input
                name="trim_end"
                type="number"
                min={start + 3}
                max={Math.min(duration, start + 120)}
                step="0.1"
                required
                value={end}
                onChange={(e) => setEnd(Number(e.target.value))}
              />
            </label>
            <button
              type="button"
              className="small-button"
              disabled={invalid || !!error}
              onClick={() => {
                if (audio.current) {
                  audio.current.currentTime = start;
                  void audio.current.play().catch((e) => setError(e.message));
                }
              }}
            >
              <Play size={13} />
              Preview selection
            </button>
          </div>
          <p className="field-help">
            Use 3–120 seconds of one clear voice. If you trim the audio, the
            transcript should match the selected portion.
          </p>
          {(invalid || error) && (
            <p className="job-error" role="alert">
              {error || "Choose a selection between 3 and 120 seconds."}
            </p>
          )}
        </div>
      )}
    </>
  );
}

export function ReferencePreview({ id }: { id: string }) {
  const [url, setURL] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  useEffect(
    () => () => {
      if (url) URL.revokeObjectURL(url);
    },
    [url],
  );
  async function load() {
    setLoading(true);
    try {
      setURL(await mediaURL(`/v1/voices/${id}/reference`));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }
  return (
    <div className="reference-preview">
      {url ? (
        <audio src={url} controls aria-label="Voice reference recording" />
      ) : (
        <button
          className="small-button"
          disabled={loading}
          onClick={() => void load()}
        >
          <Volume2 size={14} />
          {loading ? "Loading…" : "Preview reference"}
        </button>
      )}
      {error && (
        <p className="job-error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}
