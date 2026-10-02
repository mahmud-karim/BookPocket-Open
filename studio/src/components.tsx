import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  BookOpen,
  ChevronLeft,
  ChevronRight,
  Pause,
  Play,
  SkipBack,
  SkipForward,
  Volume2,
  X,
} from "lucide-react";
import { mediaURL } from "./api";
import { bookColor, duration } from "./format";
import type { Asset, Book } from "./types";

export function Cover({
  book,
  small = false,
}: {
  book: Book;
  small?: boolean;
}) {
  const [image, setImage] = useState<string>();
  useEffect(() => {
    let disposed = false;
    let url: string | undefined;
    setImage(undefined);
    if (book.cover_url)
      void mediaURL(book.cover_url)
        .then((value) => {
          url = value;
          if (!disposed) setImage(value);
          else URL.revokeObjectURL(value);
        })
        .catch(() => {});
    return () => {
      disposed = true;
      if (url) URL.revokeObjectURL(url);
    };
  }, [book.cover_url]);
  return (
    <div
      className={`book-cover ${bookColor(book.id)} ${small ? "small" : ""}`}
      aria-hidden="true"
    >
      {image ? (
        <img src={image} alt="" />
      ) : (
        <>
          <div className="cover-line" />
          <BookOpen
            className="cover-mark"
            size={small ? 20 : 30}
            strokeWidth={1}
          />
          <span className="cover-title">{book.title}</span>
          <span className="cover-author">{book.author}</span>
          <div className="cover-line bottom" />
        </>
      )}
    </div>
  );
}
export function Empty({
  icon,
  title,
  children,
  action,
}: {
  icon: ReactNode;
  title: string;
  children: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <div className="empty-icon">{icon}</div>
      <h2>{title}</h2>
      <p>{children}</p>
      {action}
    </div>
  );
}
export function Modal({
  title,
  children,
  onClose,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    d?.showModal();
    return () => d?.close();
  }, []);
  return (
    <dialog ref={ref} onCancel={onClose} aria-label={title}>
      <div className="dialog-title">
        <h2>{title}</h2>
        <button
          className="icon-button"
          aria-label="Close dialog"
          onClick={onClose}
        >
          <X size={20} />
        </button>
      </div>
      {children}
    </dialog>
  );
}
export type Playback = { book: Book; assets: Asset[]; index: number };
export function Player({
  playback,
  onClose,
  onIndex,
  onError,
}: {
  playback: Playback;
  onClose: () => void;
  onIndex: (index: number) => void;
  onError: (error: string) => void;
}) {
  const audio = useRef<HTMLAudioElement>(null);
  const [src, setSrc] = useState<string>();
  const [playing, setPlaying] = useState(false);
  const [time, setTime] = useState(0);
  const [length, setLength] = useState(0);
  const [speed, setSpeed] = useState(1);
  const asset = playback.assets[playback.index];
  useEffect(() => {
    let disposed = false;
    let objectURL: string | undefined;
    setSrc(undefined);
    setTime(0);
    setPlaying(false);
    void mediaURL(asset.url)
      .then((url) => {
        objectURL = url;
        if (!disposed) setSrc(url);
        else URL.revokeObjectURL(url);
      })
      .catch((e) => {
        if (!disposed) onError(e.message);
      });
    return () => {
      disposed = true;
      if (objectURL) URL.revokeObjectURL(objectURL);
    };
  }, [asset.id, asset.url]);
  useEffect(() => {
    const el = audio.current;
    if (!el || !src) return;
    el.playbackRate = speed;
    void el.play().catch(() => {
      setPlaying(false);
    });
  }, [src]);
  useEffect(() => {
    if (audio.current) audio.current.playbackRate = speed;
  }, [speed]);
  useEffect(() => {
    if (!("mediaSession" in navigator)) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: playback.book.title,
      artist: playback.book.author,
      album: "Book Pocket",
    });
    navigator.mediaSession.setActionHandler("play", () => {
      void audio.current?.play();
    });
    navigator.mediaSession.setActionHandler("pause", () =>
      audio.current?.pause(),
    );
    navigator.mediaSession.setActionHandler("seekbackward", () => {
      if (audio.current)
        audio.current.currentTime = Math.max(0, audio.current.currentTime - 15);
    });
    navigator.mediaSession.setActionHandler("seekforward", () => {
      if (audio.current)
        audio.current.currentTime = Math.min(
          audio.current.duration || 0,
          audio.current.currentTime + 15,
        );
    });
    return () => {
      for (const action of [
        "play",
        "pause",
        "seekbackward",
        "seekforward",
      ] as MediaSessionAction[])
        navigator.mediaSession.setActionHandler(action, null);
    };
  }, [playback.book]);
  const seek = (delta: number) => {
    if (audio.current)
      audio.current.currentTime = Math.min(
        length,
        Math.max(0, audio.current.currentTime + delta),
      );
  };
  return (
    <section className="player" aria-label="Audio player">
      <audio
        ref={audio}
        src={src}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onTimeUpdate={() => setTime(audio.current?.currentTime ?? 0)}
        onLoadedMetadata={() =>
          setLength(audio.current?.duration ?? asset.duration)
        }
        onEnded={() => {
          if (playback.index + 1 < playback.assets.length)
            onIndex(playback.index + 1);
        }}
        onError={() =>
          onError(
            "This recording could not be played. Try downloading it again.",
          )
        }
      />
      <div className="player-book">
        <Cover book={playback.book} small />
        <div>
          <strong>{playback.book.title}</strong>
          <span>
            Passage {playback.index + 1} of {playback.assets.length}
          </span>
        </div>
      </div>
      <div className="player-center">
        <div className="transport">
          <button
            className="icon-button"
            disabled={playback.index === 0}
            aria-label="Previous passage"
            onClick={() => onIndex(playback.index - 1)}
          >
            <ChevronLeft size={19} />
          </button>
          <button
            className="icon-button"
            aria-label="Back 15 seconds"
            onClick={() => seek(-15)}
          >
            <SkipBack size={18} />
          </button>
          <button
            className="play-button"
            disabled={!src}
            aria-label={playing ? "Pause" : "Play"}
            onClick={() => {
              if (playing) audio.current?.pause();
              else void audio.current?.play().catch((e) => onError(e.message));
            }}
          >
            {playing ? <Pause size={19} /> : <Play size={19} />}
          </button>
          <button
            className="icon-button"
            aria-label="Forward 15 seconds"
            onClick={() => seek(15)}
          >
            <SkipForward size={18} />
          </button>
          <button
            className="icon-button"
            disabled={playback.index + 1 >= playback.assets.length}
            aria-label="Next passage"
            onClick={() => onIndex(playback.index + 1)}
          >
            <ChevronRight size={19} />
          </button>
        </div>
        <div className="seek">
          <span>{duration(time)}</span>
          <input
            aria-label="Playback position"
            type="range"
            min="0"
            max={length || 1}
            step="0.1"
            value={Math.min(time, length || 1)}
            onChange={(e) => {
              if (audio.current)
                audio.current.currentTime = Number(e.target.value);
            }}
          />
          <span>{duration(length)}</span>
        </div>
      </div>
      <div className="player-extra">
        <label className="sr-only" htmlFor="playback-speed">
          Playback speed
        </label>
        <select
          id="playback-speed"
          value={speed}
          onChange={(e) => setSpeed(Number(e.target.value))}
        >
          {[0.75, 1, 1.25, 1.5, 1.75, 2].map((n) => (
            <option key={n} value={n}>
              {n}×
            </option>
          ))}
        </select>
        <Volume2 size={18} />
        <button
          className="icon-button"
          aria-label="Close player"
          onClick={onClose}
        >
          <X size={18} />
        </button>
      </div>
    </section>
  );
}
