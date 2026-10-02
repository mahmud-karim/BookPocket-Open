import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type FormEvent,
} from "react";
import {
  ArrowDownToLine,
  ArrowLeft,
  ArrowRight,
  AudioLines,
  BookOpen,
  Check,
  ChevronRight,
  Clock,
  Headphones,
  Library,
  LoaderCircle,
  Monitor,
  MoreHorizontal,
  Pause,
  Play,
  Plus,
  RefreshCw,
  Search,
  Settings,
  ShieldCheck,
  Smartphone,
  Sun,
  Trash2,
  Upload,
  Users,
  Volume2,
  X,
} from "lucide-react";
import QRCode from "qrcode";
import { VoiceSampleInput, ReferencePreview } from "./VoiceSample";
import { EngineList, AnalyzerSettings } from "./EngineSettings";
import { CastEditor } from "./CastEditor";
import { narrationPlan, type Cast } from "./casting";
import { api, bootstrapSession, post, saveAsset, submitJob } from "./api";
import { Cover, Empty, Modal, Player, type Playback } from "./components";
import { duration, initials, jobProgress } from "./format";
import type {
  Asset,
  Book,
  Device,
  Engine,
  Job,
  Pairing,
  PronunciationRule,
  Snapshot,
  Voice,
} from "./types";

type Tab = "library" | "listen" | "studio" | "voices" | "devices" | "settings";
const initial: Snapshot = { books: [], voices: [], engines: [], jobs: [] };
const tabs = [
  { id: "library", label: "Library", icon: Library },
  { id: "listen", label: "Listen", icon: Headphones },
  { id: "studio", label: "Studio", icon: AudioLines },
  { id: "voices", label: "Voices", icon: Users },
  { id: "devices", label: "Devices", icon: Smartphone },
] as const;
function loadPreference<T>(key: string, fallback: T): T {
  try {
    return JSON.parse(localStorage.getItem(key) ?? "null") ?? fallback;
  } catch {
    return fallback;
  }
}

export function App() {
  const [authorized] = useState(bootstrapSession);
  const [data, setData] = useState(initial);
  const [tab, setTab] = useState<Tab>("library");
  const [loading, setLoading] = useState(authorized);
  const [online, setOnline] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string>();
  const [modal, setModal] = useState<"import" | "voice" | null>(null);
  const [playback, setPlayback] = useState<Playback>();
  const [theme, setTheme] = useState(() => loadPreference("bp.theme", "dark"));
  const upload = useRef<HTMLInputElement>(null);
  const refresh = useCallback(async () => {
    if (!authorized) return;
    try {
      const [books, voices, engines, jobs] = await Promise.all([
        api<{ books: Book[] }>("/v1/books"),
        api<{ voices: Voice[] }>("/v1/voices"),
        api<{ engines: Engine[] }>("/v1/engines"),
        api<{ jobs: Job[] }>("/v1/jobs"),
      ]);
      setData({ ...books, ...voices, ...engines, ...jobs });
      setOnline(true);
    } catch (e) {
      setOnline(false);
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [authorized]);
  useEffect(() => {
    void refresh();
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") void refresh();
    }, 5000);
    return () => clearInterval(timer);
  }, [refresh]);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("bp.theme", JSON.stringify(theme));
  }, [theme]);
  async function run(fn: () => Promise<void>) {
    setBusy(true);
    setError("");
    try {
      await fn();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function importFile(file: File) {
    await run(async () => {
      const body = new FormData();
      body.append("file", file);
      const book = file.name.toLowerCase().endsWith(".zip")
        ? (
            await api<{ book: Book; job: Job }>("/v1/projects/import", {
              method: "POST",
              body,
            })
          ).book
        : await api<Book>("/v1/books", { method: "POST", body });
      await refresh();
      setSelected(book.id);
      setTab("library");
      setModal(null);
      setNotice(`“${book.title}” is in your library.`);
    });
  }
  function play(job: Job) {
    const book = data.books.find((b) => b.id === job.book_id);
    if (book && job.assets.length)
      setPlayback({ book, assets: job.assets, index: 0 });
  }
  const book = data.books.find((b) => b.id === selected);
  const active = data.jobs.filter((j) =>
    ["running", "queued"].includes(j.status),
  );
  const filtered = data.books.filter((b) =>
    `${b.title} ${b.author}`
      .toLocaleLowerCase()
      .includes(query.toLocaleLowerCase()),
  );
  const navigate = (next: Tab) => {
    setTab(next);
    setSelected(undefined);
    setQuery("");
  };
  return (
    <div className={`app-shell ${playback ? "has-player" : ""}`}>
      <aside className="sidebar">
        <button
          className="brand"
          onClick={() => navigate("library")}
          aria-label="Book Pocket home"
        >
          <img src="/book-pocket.svg" alt="" />
          <span>
            Book Pocket<small>OPEN STUDIO</small>
          </span>
        </button>
        <div className="sidebar-rule" />
        <p className="eyebrow nav-label">YOUR SPACE</p>
        <nav aria-label="Main navigation">
          {tabs.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              className={`nav-item ${tab === id ? "active" : ""}`}
              aria-current={tab === id ? "page" : undefined}
              onClick={() => navigate(id)}
            >
              <Icon size={19} />
              <span>{label}</span>
              {id === "studio" && active.length > 0 ? (
                <span className="count">{active.length}</span>
              ) : null}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="local-status">
            <span className={`status-dot ${online ? "ready" : ""}`} />
            <div>
              <strong>
                {online ? "Companion connected" : "Companion offline"}
              </strong>
              <small>Your library. Your machine.</small>
            </div>
          </div>
          <button
            className={`nav-item ${tab === "settings" ? "active" : ""}`}
            onClick={() => navigate("settings")}
          >
            <Settings size={19} />
            Settings
          </button>
        </div>
      </aside>
      <div className="workspace">
        <header className="topbar">
          <span className="breadcrumb">
            Your space <ChevronRight size={13} />{" "}
            {tabs.find((t) => t.id === tab)?.label ?? "Settings"}
            {book && (
              <>
                {" "}
                <ChevronRight size={13} />
                <span className="truncate">{book.title}</span>
              </>
            )}
          </span>
          <div className="top-actions">
            <span className="local-badge">
              <ShieldCheck size={14} />
              Private by default
            </span>
            <button
              className="icon-button"
              onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
              aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
            >
              <Sun size={18} />
            </button>
          </div>
        </header>
        <main id="main-content">
          {error && (
            <div className="banner error" role="alert">
              <span>{error}</span>
              <button
                className="icon-button"
                aria-label="Dismiss error"
                onClick={() => setError("")}
              >
                <X size={17} />
              </button>
            </div>
          )}
          {notice && (
            <div className="banner success" role="status">
              <Check size={17} />
              <span>{notice}</span>
              <button
                className="icon-button"
                aria-label="Dismiss message"
                onClick={() => setNotice("")}
              >
                <X size={17} />
              </button>
            </div>
          )}
          {!authorized ? (
            <Empty
              icon={<Monitor size={38} />}
              title="Your studio, on your computer"
            >
              Open Book Pocket from its desktop shortcut or tray menu to
              securely connect this window to your companion.
            </Empty>
          ) : loading ? (
            <div className="loading" role="status">
              <LoaderCircle className="spin" />
              Opening your library…
            </div>
          ) : (
            <>
              {tab === "library" && !book && (
                <>
                  <div className="page-title">
                    <div>
                      <p className="eyebrow">
                        A LITTLE SPACE FOR GREAT STORIES
                      </p>
                      <h1>
                        Your library<span className="title-dot">.</span>
                      </h1>
                      <p className="subheading">
                        A book to get lost in. A voice to bring it to life.
                      </p>
                    </div>
                    <button
                      className="primary"
                      onClick={() => setModal("import")}
                    >
                      <Plus size={17} />
                      Import book
                    </button>
                  </div>
                  {data.books.length === 0 ? (
                    <Empty
                      icon={<BookOpen size={40} />}
                      title="Make room for your next story"
                      action={
                        <button
                          className="primary"
                          onClick={() => setModal("import")}
                        >
                          <Upload size={17} />
                          Choose a book
                        </button>
                      }
                    >
                      Import an EPUB or text file. Keep the original, create an
                      audiobook, and take the story with you.
                    </Empty>
                  ) : (
                    <>
                      {!query && (
                        <section className="featured">
                          <div className="feature-art">
                            <Cover book={data.books[0]} />
                          </div>
                          <div className="feature-copy">
                            <span className="eyebrow accent">
                              ON YOUR BOOKSHELF
                            </span>
                            <h2>{data.books[0].title}</h2>
                            <p className="feature-author">
                              {data.books[0].author}
                            </p>
                            <div className="feature-meta">
                              <span>
                                <BookOpen size={15} />
                                {data.books[0].chapters.length} chapters
                              </span>
                              <span>
                                <ShieldCheck size={15} />
                                Stored on this PC
                              </span>
                            </div>
                            <div className="button-row">
                              <button
                                className="primary"
                                onClick={() => setSelected(data.books[0].id)}
                              >
                                <BookOpen size={17} />
                                Open book
                              </button>
                              <button
                                className="secondary"
                                onClick={() => {
                                  setSelected(data.books[0].id);
                                  setTab("studio");
                                }}
                              >
                                <AudioLines size={17} />
                                Create audiobook
                              </button>
                            </div>
                          </div>
                          <div className="feature-ornament" aria-hidden="true">
                            <AudioLines strokeWidth={0.4} />
                          </div>
                        </section>
                      )}
                      <div className="section-heading">
                        <div>
                          <h2>
                            On the shelf{" "}
                            <span className="muted-count">
                              {data.books.length}
                            </span>
                          </h2>
                        </div>
                        <label className="search">
                          <Search size={17} />
                          <input
                            aria-label="Search books"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                            placeholder="Find a book or author"
                          />
                        </label>
                      </div>
                      <div className="book-grid">
                        {filtered.map((b) => (
                          <button
                            className="book-tile"
                            key={b.id}
                            onClick={() => setSelected(b.id)}
                          >
                            <Cover book={b} />
                            <strong>{b.title}</strong>
                            <span>{b.author}</span>
                            <small>
                              {b.chapters.length} chapters{" "}
                              <ArrowRight size={13} />
                            </small>
                          </button>
                        ))}
                      </div>
                      {filtered.length === 0 && (
                        <p className="empty-search">
                          No books match “{query}”.
                        </p>
                      )}
                    </>
                  )}
                </>
              )}
              {(tab === "library" || tab === "studio") && book && (
                <BookStudio
                  key={book.id}
                  book={book}
                  voices={data.voices}
                  engines={data.engines}
                  jobs={data.jobs.filter((j) => j.book_id === book.id)}
                  busy={busy}
                  onBack={() => setSelected(undefined)}
                  onGenerate={(body) =>
                    run(async () => {
                      const job = await submitJob<Job>(body);
                      await refresh();
                      setNotice(
                        job.status === "completed"
                          ? "This recording is ready."
                          : "Your audiobook is in the queue.",
                      );
                      setTab("studio");
                    })
                  }
                  onPlay={play}
                  onError={setError}
                />
              )}
              {tab === "listen" && (
                <>
                  <div className="page-title">
                    <div>
                      <p className="eyebrow">LET THE STORY COME TO YOU</p>
                      <h1>
                        Listen<span className="title-dot">.</span>
                      </h1>
                      <p className="subheading">
                        Your finished recordings, ready for another chapter.
                      </p>
                    </div>
                  </div>
                  {data.jobs.some((j) => j.assets.length) ? (
                    <div className="recordings">
                      {data.jobs
                        .filter((j) => j.assets.length > 0)
                        .map((j) => (
                          <JobCard
                            key={j.id}
                            job={j}
                            book={data.books.find((b) => b.id === j.book_id)}
                            voices={data.voices}
                            onPlay={() => play(j)}
                            onAction={(action) =>
                              run(async () => {
                                if (
                                  ["mp3", "m4b", "project"].includes(action)
                                ) {
                                  const asset = await post<Asset>(
                                    `/v1/jobs/${j.id}/export`,
                                    { format: action },
                                  );
                                  await saveAsset(
                                    asset.url,
                                    `audiobook.${action === "project" ? "zip" : action}`,
                                  );
                                } else await post(`/v1/jobs/${j.id}/${action}`);
                                await refresh();
                              })
                            }
                            busy={busy}
                          />
                        ))}
                    </div>
                  ) : (
                    <Empty
                      icon={<Headphones size={40} />}
                      title="A listening shelf of your own"
                      action={
                        <button
                          className="secondary"
                          onClick={() => navigate("library")}
                        >
                          Choose a book
                          <ArrowRight size={16} />
                        </button>
                      }
                    >
                      Generate a chapter or a complete book. Your finished
                      recordings will appear here.
                    </Empty>
                  )}
                </>
              )}
              {tab === "studio" && !book && (
                <>
                  <div className="page-title">
                    <div>
                      <p className="eyebrow">FROM THE PAGE TO YOUR EARS</p>
                      <h1>
                        The studio<span className="title-dot">.</span>
                      </h1>
                      <p className="subheading">
                        Thoughtful narration, one passage at a time.
                      </p>
                    </div>
                    <button
                      className="secondary"
                      onClick={() => navigate("library")}
                    >
                      <Plus size={17} />
                      New audiobook
                    </button>
                  </div>
                  {data.jobs.length ? (
                    <>
                      <div className="section-heading">
                        <h2>Generation queue</h2>
                        <span className="muted">{active.length} active</span>
                      </div>
                      <div className="recordings">
                        {data.jobs.map((j) => (
                          <JobCard
                            key={j.id}
                            job={j}
                            book={data.books.find((b) => b.id === j.book_id)}
                            voices={data.voices}
                            onPlay={() => play(j)}
                            busy={busy}
                            onAction={(action) =>
                              run(async () => {
                                if (
                                  ["mp3", "m4b", "project"].includes(action)
                                ) {
                                  const asset = await post<Asset>(
                                    `/v1/jobs/${j.id}/export`,
                                    { format: action },
                                  );
                                  await saveAsset(
                                    asset.url,
                                    `audiobook.${action === "project" ? "zip" : action}`,
                                  );
                                } else await post(`/v1/jobs/${j.id}/${action}`);
                                await refresh();
                              })
                            }
                          />
                        ))}
                      </div>
                    </>
                  ) : (
                    <Empty
                      icon={<AudioLines size={40} />}
                      title="Every story deserves a voice"
                      action={
                        <button
                          className="primary"
                          onClick={() => navigate("library")}
                        >
                          Choose from your library
                          <ArrowRight size={16} />
                        </button>
                      }
                    >
                      Pick a book, choose a narrator, and make your first
                      audiobook.
                    </Empty>
                  )}
                </>
              )}
              {tab === "voices" && (
                <>
                  <div className="page-title">
                    <div>
                      <p className="eyebrow">FIND THE VOICE OF YOUR STORY</p>
                      <h1>
                        Voice collection<span className="title-dot">.</span>
                      </h1>
                      <p className="subheading">
                        Distinct voices, familiar characters, endless
                        possibilities.
                      </p>
                    </div>
                    <button
                      className="primary"
                      disabled={
                        !data.engines.some(
                          (e) => e.available && e.supports_cloning,
                        )
                      }
                      onClick={() => setModal("voice")}
                    >
                      <Plus size={17} />
                      Create a voice
                    </button>
                  </div>
                  {data.voices.length ? (
                    <div className="voice-grid">
                      {data.voices.map((v, i) => (
                        <article className="voice-card" key={v.id}>
                          <div className={`voice-orb orb-${i % 4}`}>
                            <AudioLines size={30} strokeWidth={1} />
                          </div>
                          <div>
                            <h2>{v.name}</h2>
                            <p>
                              {v.kind === "clone"
                                ? "Your voice clone"
                                : v.kind === "designed"
                                  ? "Designed voice"
                                  : "Preset narrator"}
                            </p>
                            <span className="tag">
                              {data.engines.find((e) => e.id === v.engine)
                                ?.name ?? v.engine}
                            </span>
                            <span className="tag">{v.language}</span>
                            {v.kind === "clone" &&
                              v.engine !== "voicestudio" && (
                                <ReferencePreview id={v.id} />
                              )}
                          </div>
                          {v.kind === "clone" && (
                            <button
                              className="icon-button voice-delete"
                              aria-label={`Delete voice ${v.name}`}
                              onClick={() => {
                                if (
                                  window.confirm(
                                    `Delete “${v.name}”? Existing audio stays in your library.`,
                                  )
                                )
                                  void run(async () => {
                                    await api(`/v1/voices/${v.id}`, {
                                      method: "DELETE",
                                    });
                                    await refresh();
                                  });
                              }}
                            >
                              <Trash2 size={17} />
                            </button>
                          )}
                        </article>
                      ))}
                    </div>
                  ) : (
                    <Empty
                      icon={<Users size={40} />}
                      title="Your narrators live here"
                    >
                      Set up a voice engine below, then choose a preset or
                      create a voice from a recording you have permission to
                      use.
                    </Empty>
                  )}
                  <EngineList engines={data.engines} />
                </>
              )}
              {tab === "devices" && (
                <Devices onError={setError} onNotice={setNotice} />
              )}
              {tab === "settings" && (
                <>
                  <div className="page-title">
                    <div>
                      <p className="eyebrow">MAKE YOURSELF AT HOME</p>
                      <h1>
                        Settings<span className="title-dot">.</span>
                      </h1>
                    </div>
                  </div>
                  <section className="panel settings-panel">
                    <h2>Appearance</h2>
                    <p className="muted">
                      Obsidian, in the light that suits you.
                    </p>
                    <div className="theme-choices">
                      {["dark", "light"].map((t) => (
                        <button
                          key={t}
                          className={`theme-choice ${theme === t ? "chosen" : ""}`}
                          onClick={() => setTheme(t)}
                        >
                          <span className={`theme-swatch ${t}`}>
                            <span />
                            <span />
                            <span />
                          </span>
                          <span>
                            {t === "dark" ? "Obsidian dark" : "Obsidian light"}
                            {theme === t && <Check size={16} />}
                          </span>
                        </button>
                      ))}
                    </div>
                  </section>
                  <EngineList engines={data.engines} />
                  <AnalyzerSettings />
                  <section className="panel">
                    <h2>Your data stays yours</h2>
                    <p className="muted">
                      Books, voice references, and generated audio are stored on
                      this computer. A paired phone can download its own offline
                      copy. No account is needed to read. A hosted cast analysis
                      service receives book text only after you approve that
                      analysis.
                    </p>
                    <button
                      className="secondary"
                      onClick={() => navigate("devices")}
                    >
                      <Smartphone size={17} />
                      Manage connected devices
                    </button>
                  </section>
                </>
              )}
            </>
          )}
        </main>
        <footer className="workspace-footer">
          <span>BOOK POCKET OPEN</span>
          <span>
            Built for stories. Made to be yours.{" "}
            <a href="/licenses/DM-Sans.txt" target="_blank" rel="noreferrer">
              DM Sans
            </a>{" "}
            ·{" "}
            <a href="/licenses/Literata.txt" target="_blank" rel="noreferrer">
              Literata
            </a>
          </span>
        </footer>
      </div>
      {playback && (
        <Player
          playback={playback}
          onClose={() => setPlayback(undefined)}
          onIndex={(index) => setPlayback((p) => (p ? { ...p, index } : p))}
          onError={setError}
        />
      )}
      {modal === "import" && (
        <Modal title="Add to your library" onClose={() => setModal(null)}>
          <p className="muted">
            Bring a DRM-free EPUB, plain text file, or exported Book Pocket
            project ZIP. Projects restore the original book and their
            recordings.
          </p>
          <input
            ref={upload}
            type="file"
            accept=".epub,.txt,.zip"
            className="sr-only"
            disabled={busy}
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) void importFile(f);
            }}
          />
          <button
            className="dropzone"
            disabled={busy}
            onClick={() => upload.current?.click()}
            onDragOver={(e) => e.preventDefault()}
            onDrop={(e) => {
              e.preventDefault();
              const f = e.dataTransfer.files[0];
              if (f && !busy) void importFile(f);
            }}
          >
            {busy ? (
              <LoaderCircle className="spin" size={32} />
            ) : (
              <Upload size={32} />
            )}
            <strong>
              {busy ? "Opening your book…" : "Choose a book, or drop it here"}
            </strong>
            <span>EPUB, TXT, or Book Pocket project ZIP</span>
          </button>
        </Modal>
      )}
      {modal === "voice" && (
        <VoiceDialog
          engines={data.engines.filter(
            (e) => e.available && e.supports_cloning,
          )}
          busy={busy}
          onClose={() => setModal(null)}
          onSubmit={(body) =>
            run(async () => {
              const v = await api<Voice>("/v1/voices", {
                method: "POST",
                body,
              });
              await refresh();
              setModal(null);
              setNotice(`“${v.name}” is ready to narrate.`);
            })
          }
        />
      )}
    </div>
  );
}

function JobCard({
  job,
  book,
  voices,
  busy,
  onPlay,
  onAction,
}: {
  job: Job;
  book?: Book;
  voices: Voice[];
  busy: boolean;
  onPlay: () => void;
  onAction: (action: string) => Promise<void>;
}) {
  const progress = jobProgress(job.completed_segments, job.total_segments);
  const live = ["queued", "running", "paused"].includes(job.status);
  const elapsed = job.started_at
    ? Math.max(0, (Date.now() - Date.parse(job.started_at)) / 1000)
    : 0;
  const remaining =
    job.status === "running" && job.completed_segments >= 2
      ? (elapsed / job.completed_segments) *
        (job.total_segments - job.completed_segments)
      : undefined;
  return (
    <article className="job-card">
      {book && <Cover book={book} small />}
      <div className="job-main">
        <div className="job-top">
          <div>
            <h3>{book?.title ?? "Audiobook"}</h3>
            <p>
              {voices.find((v) => v.id === job.voice_id)?.name ?? "Narrator"}{" "}
              <span>·</span> {job.total_segments} passages
            </p>
          </div>
          <span className={`status-pill ${job.status}`}>
            {job.status === "running" && (
              <LoaderCircle size={12} className="spin" />
            )}
            {job.status}
          </span>
        </div>
        {live && (
          <>
            <progress
              max="100"
              value={progress}
              aria-label={`${progress}% complete`}
            />
            <div className="job-progress">
              <span>
                {job.completed_segments} of {job.total_segments} passages ready
              </span>
              <span>
                {remaining !== undefined
                  ? `About ${duration(remaining)} remaining · `
                  : ""}
                {progress}%
              </span>
            </div>
          </>
        )}
        {job.error && <p className="job-error">{job.error}</p>}
        <div className="job-bottom">
          <span className="job-meta">
            <Clock size={13} />
            {job.generation_seconds
              ? `Generated in ${duration(job.generation_seconds)}`
              : new Date(job.created_at).toLocaleDateString()}
            {job.assets.length > 0 &&
              ` · ${duration(job.assets.reduce((n, a) => n + a.duration, 0))} audio`}
          </span>
          <div className="button-row compact">
            {job.assets.length > 0 && (
              <button className="small-button" onClick={onPlay}>
                <Play size={14} />
                Listen
              </button>
            )}
            {job.status === "completed" && (
              <>
                <button
                  className="small-button"
                  disabled={busy}
                  onClick={() => void onAction("m4b")}
                >
                  <ArrowDownToLine size={14} />
                  M4B
                </button>
                <details className="export-menu">
                  <summary aria-label="More export formats">
                    <MoreHorizontal size={18} />
                  </summary>
                  <div>
                    <button
                      disabled={busy}
                      onClick={() => void onAction("mp3")}
                    >
                      Export MP3
                    </button>
                    <button
                      disabled={busy}
                      onClick={() => void onAction("project")}
                    >
                      Export project
                    </button>
                  </div>
                </details>
              </>
            )}
            {["running", "queued"].includes(job.status) && (
              <button
                className="small-button"
                disabled={busy}
                onClick={() => void onAction("pause")}
              >
                <Pause size={14} />
                Pause
              </button>
            )}
            {job.status === "paused" && (
              <button
                className="small-button"
                disabled={busy}
                onClick={() => void onAction("resume")}
              >
                <Play size={14} />
                Resume
              </button>
            )}
            {["failed", "cancelled"].includes(job.status) && (
              <button
                className="small-button"
                disabled={busy}
                onClick={() => void onAction("retry")}
              >
                <RefreshCw size={14} />
                Retry
              </button>
            )}
            {live && (
              <button
                className="icon-button"
                disabled={busy}
                aria-label="Cancel generation"
                onClick={() => void onAction("cancel")}
              >
                <X size={15} />
              </button>
            )}
          </div>
        </div>
      </div>
    </article>
  );
}

function VoiceDialog({
  engines,
  busy,
  onClose,
  onSubmit,
}: {
  engines: Engine[];
  busy: boolean;
  onClose: () => void;
  onSubmit: (body: FormData) => Promise<void>;
}) {
  const [engine, setEngine] = useState(engines[0]?.id ?? "");
  const [permission, setPermission] = useState(false);
  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    await onSubmit(new FormData(e.currentTarget));
  }
  return (
    <Modal title="Create a voice" onClose={onClose}>
      <form onSubmit={(e) => void submit(e)} className="form-stack">
        <p className="muted">
          A clear, single-speaker recording gives your narrator a voice of its
          own.
        </p>
        <label>
          Voice name
          <input name="name" required maxLength={80} placeholder="e.g. Clara" />
        </label>
        <label>
          Voice engine
          <select
            name="engine"
            value={engine}
            onChange={(e) => setEngine(e.target.value)}
          >
            {engines.map((e) => (
              <option value={e.id} key={e.id}>
                {e.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          Language
          <select name="language">
            {(engines.find((e) => e.id === engine)?.languages ?? ["en"]).map(
              (l) => (
                <option key={l}>{l}</option>
              ),
            )}
          </select>
        </label>
        <VoiceSampleInput />
        <label>
          What is said in the recording{" "}
          <span className="muted">(optional)</span>
          <textarea
            name="transcript"
            rows={3}
            placeholder="An accurate transcript can improve the result."
          />
        </label>
        <label className="checkbox">
          <input
            type="checkbox"
            required
            checked={permission}
            onChange={(e) => setPermission(e.target.checked)}
          />
          I own this voice or have permission to use it.
        </label>
        <button className="primary wide" disabled={busy || !permission}>
          {busy ? (
            <LoaderCircle className="spin" size={18} />
          ) : (
            <AudioLines size={18} />
          )}
          Create voice
        </button>
      </form>
    </Modal>
  );
}

function BookStudio({
  book,
  voices,
  engines,
  jobs,
  busy,
  onBack,
  onGenerate,
  onPlay,
  onError,
}: {
  book: Book;
  voices: Voice[];
  engines: Engine[];
  jobs: Job[];
  busy: boolean;
  onBack: () => void;
  onGenerate: (body: Record<string, unknown>) => Promise<void>;
  onPlay: (job: Job) => void;
  onError: (message: string) => void;
}) {
  const [chapter, setChapter] = useState(0);
  const [scope, setScope] = useState<"chapter" | "book" | "selection">(
    "chapter",
  );
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [engine, setEngine] = useState(
    () => engines.find((e) => e.available)?.id ?? "",
  );
  const [voice, setVoice] = useState("");
  const [rules, setRules] = useState<PronunciationRule[]>(() =>
    loadPreference(`bp.rules.${book.id}`, []),
  );
  const [announce, setAnnounce] = useState(true);
  const [surface, setSurface] = useState(() =>
    loadPreference("bp.reader.surface", "dark"),
  );
  const [fontSize, setFontSize] = useState(19);
  const [fullCast, setFullCast] = useState(false);
  const [cast, setCast] = useState<Cast>();
  const [castSaved, setCastSaved] = useState(false);
  const receiveCast = useCallback((value: Cast | undefined, saved: boolean) => {
    setCast(value);
    setCastSaved(saved);
  }, []);
  const current = book.chapters[chapter];
  const availableVoices = voices.filter((v) => v.engine === engine);
  const chosenVoice = availableVoices.some((v) => v.id === voice)
    ? voice
    : (availableVoices[0]?.id ?? "");
  const available = engines.find((e) => e.id === engine)?.available ?? false;
  useEffect(() => {
    localStorage.setItem(`bp.rules.${book.id}`, JSON.stringify(rules));
  }, [book.id, rules]);
  useEffect(() => {
    localStorage.setItem("bp.reader.surface", JSON.stringify(surface));
  }, [surface]);
  const segments =
    scope === "book"
      ? book.chapters.flatMap((c) => c.segments)
      : scope === "selection"
        ? book.chapters
            .flatMap((c) => c.segments)
            .filter((s) => selected.has(s.id))
        : (current?.segments ?? []);
  async function generate() {
    if (!chosenVoice) {
      onError("Choose an available narrator first.");
      return;
    }
    let plan;
    let narrator = chosenVoice;
    try {
      if (fullCast) {
        if (!cast || !castSaved)
          throw new Error("Save your cast before generating.");
        plan = narrationPlan(cast, segments, voices, engine);
        const override = cast.characters.find(c => c.id === "narrator")?.voice_id;
        if (override) {
          if (!voices.some(v => v.id === override && v.engine === engine)) {
            throw new Error("Choose a narrator voice from the selected engine in your cast.");
          }
          narrator = override;
        }
      }
    } catch (e) {
      onError((e as Error).message);
      return;
    }
    await onGenerate({
      narration_plan: plan ?? [],
      request_id: crypto.randomUUID(),
      book_id: book.id,
      segment_ids: segments.map((s) => s.id),
      engine,
      voice_id: narrator,
      language: book.language || "en",
      pronunciation_rules: rules.filter(
        (r) => r.term.trim() && r.replacement.trim(),
      ),
      announce_chapters: announce,
    });
  }
  return (
    <>
      <button className="back-button" onClick={onBack}>
        <ArrowLeft size={16} />
        Back to library
      </button>
      <div className="book-heading">
        <Cover book={book} small />
        <div>
          <p className="eyebrow">YOUR AUDIOBOOK PROJECT</p>
          <h1>{book.title}</h1>
          <p className="subheading">
            {book.author} <span>·</span> {book.chapters.length} chapters
          </p>
        </div>
      </div>
      <div className="production-layout">
        <section className={`manuscript surface-${surface}`}>
          <div className="reader-toolbar">
            <select
              aria-label="Chapter"
              value={chapter}
              onChange={(e) => setChapter(Number(e.target.value))}
            >
              {book.chapters.map((c, i) => (
                <option key={c.id} value={i}>
                  {c.title}
                </option>
              ))}
            </select>
            <div className="button-row compact">
              <button
                className="icon-button"
                aria-label="Decrease text size"
                onClick={() => setFontSize((n) => Math.max(15, n - 1))}
              >
                A−
              </button>
              <button
                className="icon-button"
                aria-label="Increase text size"
                onClick={() => setFontSize((n) => Math.min(30, n + 1))}
              >
                A+
              </button>
              <select
                aria-label="Reading background"
                value={surface}
                onChange={(e) => setSurface(e.target.value)}
              >
                <option value="dark">Dark</option>
                <option value="cream">Cream</option>
                <option value="white">White</option>
              </select>
            </div>
          </div>
          <div className="manuscript-body" style={{ fontSize }}>
            <p className="chapter-number">CHAPTER {chapter + 1}</p>
            <h2>{current?.title}</h2>
            <div className="chapter-divider">· · ·</div>
            {current?.segments.map((s) => (
              <div
                key={s.id}
                className={`source-segment ${selected.has(s.id) ? "selected" : ""}`}
              >
                {scope === "selection" && (
                  <input
                    type="checkbox"
                    aria-label={`Select passage: ${s.text.slice(0, 60)}`}
                    checked={selected.has(s.id)}
                    onChange={() =>
                      setSelected((old) => {
                        const n = new Set(old);
                        if (n.has(s.id)) n.delete(s.id);
                        else n.add(s.id);
                        return n;
                      })
                    }
                  />
                )}{" "}
                {s.kind === "heading" ? <h3>{s.text}</h3> : <p>{s.text}</p>}
              </div>
            ))}
          </div>
          <div className="reader-footer">
            <button
              className="small-button"
              disabled={chapter === 0}
              onClick={() => setChapter((n) => n - 1)}
            >
              <ArrowLeft size={14} />
              Previous
            </button>
            <span>
              {chapter + 1} / {book.chapters.length}
            </span>
            <button
              className="small-button"
              disabled={chapter + 1 >= book.chapters.length}
              onClick={() => setChapter((n) => n + 1)}
            >
              Next
              <ArrowRight size={14} />
            </button>
          </div>
        </section>
        <aside className="generation-panel">
          <div className="panel">
            <div className="section-heading">
              <h2>Narration</h2>
              <AudioLines size={20} />
            </div>
            <div className="form-stack">
              <label>
                Voice engine
                <select
                  value={engine}
                  onChange={(e) => {
                    setEngine(e.target.value);
                    setVoice("");
                  }}
                >
                  <option value="" disabled>
                    Choose an engine
                  </option>
                  {engines.map((e) => (
                    <option value={e.id} disabled={!e.available} key={e.id}>
                      {e.name}
                      {!e.available ? " · unavailable" : ""}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Narrator
                <select
                  value={chosenVoice}
                  onChange={(e) => setVoice(e.target.value)}
                >
                  <option value="" disabled>
                    Choose a voice
                  </option>
                  {availableVoices.map((v) => (
                    <option key={v.id} value={v.id}>
                      {v.name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Read
                <select
                  value={scope}
                  onChange={(e) => setScope(e.target.value as typeof scope)}
                >
                  <option value="chapter">This chapter</option>
                  <option value="book">The whole book</option>
                  <option value="selection">Selected passages</option>
                </select>
              </label>
              <label className="checkbox">
                <input
                  type="checkbox"
                  checked={fullCast}
                  onChange={(e) => setFullCast(e.target.checked)}
                />
                Use a full cast
              </label>
              <label className="checkbox">
                <input
                  type="checkbox"
                  checked={announce}
                  onChange={(e) => setAnnounce(e.target.checked)}
                />
                Announce chapter titles
              </label>
              <div className="generation-estimate">
                <span>{segments.length} passages</span>
                <span>
                  {segments
                    .reduce((n, s) => n + s.text.length, 0)
                    .toLocaleString()}{" "}
                  characters
                </span>
              </div>
              <button
                className="primary wide"
                disabled={
                  busy ||
                  !available ||
                  !chosenVoice ||
                  segments.length === 0 ||
                  (fullCast && !castSaved)
                }
                onClick={() => void generate()}
              >
                {busy ? (
                  <LoaderCircle className="spin" size={17} />
                ) : (
                  <AudioLines size={17} />
                )}
                Generate{" "}
                {scope === "book"
                  ? "book"
                  : scope === "selection"
                    ? "selection"
                    : "chapter"}
              </button>
              {!available && (
                <p className="field-help">
                  Set up an engine in Voices to begin narration.
                </p>
              )}
            </div>
          </div>
          <section className="panel pronunciations">
            <div className="section-heading">
              <h2>Pronunciation</h2>
              <button
                className="icon-button"
                aria-label="Add pronunciation correction"
                onClick={() =>
                  setRules((old) => [
                    ...old,
                    { term: "", replacement: "", enabled: true },
                  ])
                }
              >
                <Plus size={18} />
              </button>
            </div>
            {rules.length === 0 ? (
              <p className="muted">
                Give unusual names and words the right sound. Your book text
                stays unchanged.
              </p>
            ) : (
              rules.map((r, i) => (
                <div className="pronunciation-row" key={i}>
                  <input
                    aria-label={`Original word ${i + 1}`}
                    placeholder="Written word"
                    value={r.term}
                    onChange={(e) =>
                      setRules((old) =>
                        old.map((x, j) =>
                          j === i ? { ...x, term: e.target.value } : x,
                        ),
                      )
                    }
                  />
                  <input
                    aria-label={`Say it like ${i + 1}`}
                    placeholder="Say it like…"
                    value={r.replacement}
                    onChange={(e) =>
                      setRules((old) =>
                        old.map((x, j) =>
                          j === i ? { ...x, replacement: e.target.value } : x,
                        ),
                      )
                    }
                  />
                  <button
                    className="icon-button"
                    aria-label={`Remove correction ${i + 1}`}
                    onClick={() =>
                      setRules((old) => old.filter((_, j) => j !== i))
                    }
                  >
                    <X size={15} />
                  </button>
                </div>
              ))
            )}
          </section>
          {jobs.some((j) => j.assets.length > 0) && (
            <section className="panel">
              <h2>Recordings</h2>
              {jobs
                .filter((j) => j.assets.length > 0)
                .map((j, i) => (
                  <button
                    className="take-row"
                    key={j.id}
                    onClick={() => onPlay(j)}
                  >
                    <span className="round-play">
                      <Play size={14} />
                    </span>
                    <span>
                      Take {jobs.length - i}
                      <small>
                        {duration(j.assets.reduce((n, a) => n + a.duration, 0))}{" "}
                        · {j.status}
                      </small>
                    </span>
                    <ChevronRight size={16} />
                  </button>
                ))}
            </section>
          )}
        </aside>
      </div>
      {fullCast && (
        <CastEditor
          book={book}
          voices={voices}
          engine={engine}
          onChange={receiveCast}
          onError={onError}
        />
      )}
    </>
  );
}

function Devices({
  onError,
  onNotice,
}: {
  onError: (message: string) => void;
  onNotice: (message: string) => void;
}) {
  const [pairings, setPairings] = useState<Pairing[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [ticket, setTicket] = useState<{ code: string; expires_at: string }>();
  const [qr, setQR] = useState("");
  const [busy, setBusy] = useState(false);
  const refresh = useCallback(async () => {
    try {
      const [p, d] = await Promise.all([
        api<{ pairings: Pairing[] }>("/v1/admin/pairings"),
        api<{ devices: Device[] }>("/v1/admin/devices"),
      ]);
      setPairings(p.pairings);
      setDevices(d.devices);
    } catch (e) {
      onError((e as Error).message);
    }
  }, [onError]);
  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 3000);
    return () => clearInterval(timer);
  }, [refresh]);
  async function create() {
    setBusy(true);
    try {
      const [t, c] = await Promise.all([
        post<{ id: string; code: string; expires_at: string }>(
          "/v1/admin/pairing-tickets",
        ),
        api<{ url: string; certificate_sha256: string }>(
          "/v1/admin/connection",
        ),
      ]);
      if (!c.certificate_sha256 || !c.url.startsWith("https://")) {
        throw new Error(
          "Device pairing needs the secure companion launcher. Exit development mode and reopen Book Pocket from its desktop shortcut.",
        );
      }
      setTicket(t);
      setQR(
        await QRCode.toDataURL(
          JSON.stringify({
            url: c.url,
            certificate_sha256: c.certificate_sha256,
            code: t.code,
          }),
          {
            width: 256,
            margin: 2,
            color: { dark: "#111416", light: "#F4F1EA" },
          },
        ),
      );
    } catch (e) {
      onError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function decide(id: string, action: string) {
    try {
      await post(`/v1/admin/pairings/${id}/${action}`);
      await refresh();
      onNotice(
        action === "approve"
          ? "Your device is connected."
          : "Connection request declined.",
      );
    } catch (e) {
      onError((e as Error).message);
    }
  }
  return (
    <>
      <div className="page-title">
        <div>
          <p className="eyebrow">TAKE YOUR STORIES WITH YOU</p>
          <h1>
            Your devices<span className="title-dot">.</span>
          </h1>
          <p className="subheading">
            Connect your phone once. Keep your library close.
          </p>
        </div>
        <button
          className="primary"
          onClick={() => void create()}
          disabled={busy}
        >
          <Plus size={17} />
          Connect a device
        </button>
      </div>
      {ticket && (
        <section className="panel pairing-card">
          {qr && <img src={qr} alt="Pairing QR code for the Book Pocket app" />}
          <div>
            <span className="eyebrow accent">
              OPEN BOOK POCKET ON YOUR PHONE
            </span>
            <h2>Scan. Approve. You’re connected.</h2>
            <p className="muted">
              Scan this code in the app, then approve the request here.
            </p>
            <code className="pairing-code">{ticket.code}</code>
            <p className="field-help">
              Expires{" "}
              {new Date(ticket.expires_at).toLocaleTimeString([], {
                hour: "numeric",
                minute: "2-digit",
              })}
            </p>
          </div>
        </section>
      )}
      {pairings
        .filter((p) => p.status === "pending")
        .map((p) => (
          <div className="panel approval" key={p.id}>
            <Smartphone />
            <div className="grow">
              <h3>{p.device_name}</h3>
              <p className="muted">Would like to connect to your library.</p>
            </div>
            <button
              className="secondary"
              onClick={() => void decide(p.id, "reject")}
            >
              Decline
            </button>
            <button
              className="primary"
              onClick={() => void decide(p.id, "approve")}
            >
              <Check size={16} />
              Approve
            </button>
          </div>
        ))}
      {devices.length ? (
        <section className="panel">
          <h2>Connected devices</h2>
          {devices.map((d) => (
            <div className="engine-row" key={d.id}>
              <Smartphone size={23} />
              <div className="grow">
                <strong>
                  {d.name ?? d.device_name ?? "Book Pocket device"}
                </strong>
                <p>Connected {new Date(d.created_at).toLocaleDateString()}</p>
              </div>
              <button
                className="small-button"
                onClick={() => {
                  if (
                    window.confirm(
                      "Disconnect this device? Its downloaded books and audio remain on the device.",
                    )
                  )
                    void api(`/v1/admin/devices/${d.id}`, { method: "DELETE" })
                      .then(refresh)
                      .catch((e) => onError(e.message));
                }}
              >
                Disconnect
              </button>
            </div>
          ))}
        </section>
      ) : (
        !ticket && (
          <Empty
            icon={<Smartphone size={40} />}
            title="A library without borders"
          >
            Pair the iPhone app to send books and finished audio to your phone.
            Reading and downloaded listening work even when this PC is off.
          </Empty>
        )
      )}
    </>
  );
}
