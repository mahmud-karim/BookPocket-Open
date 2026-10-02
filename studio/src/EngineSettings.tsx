import { useEffect, useState, type FormEvent } from "react";
import {
  AudioLines,
  Download,
  LoaderCircle,
  Monitor,
  Save,
} from "lucide-react";
import { api, post } from "./api";
import type { Engine } from "./types";
type Installation = { engine: string; status: string; error?: string };
export function EngineList({ engines }: { engines: Engine[] }) {
  const [installations, setInstallations] = useState<Installation[]>([]);
  const [error, setError] = useState("");
  const [starting, setStarting] = useState("");
  useEffect(() => {
    let active = true;
    async function refresh() {
      try {
        const result = await api<{ installations: Installation[] }>(
          "/v1/admin/engines/installations",
        );
        if (active) setInstallations(result.installations);
      } catch (e) {
        if (active) setError((e as Error).message);
      }
    }
    void refresh();
    const timer = setInterval(() => void refresh(), 4000);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, []);
  async function install(engine: string) {
    setStarting(engine);
    setError("");
    try {
      const value = await post<Installation>(
        `/v1/admin/engines/${engine}/install`,
      );
      setInstallations((old) => [
        ...old.filter((x) => x.engine !== engine),
        value,
      ]);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setStarting("");
    }
  }
  return (
    <section className="panel engines">
      <div className="section-heading">
        <div>
          <h2>Voice engines</h2>
          <p className="muted">
            Choose the sound. Your computer does the work.
          </p>
        </div>
        <Monitor size={22} />
      </div>
      {error && (
        <p className="job-error" role="alert">
          {error}
        </p>
      )}
      {engines.length === 0 ? (
        <p className="muted">No engines were reported by the companion.</p>
      ) : (
        engines.map((e) => {
          const task = installations.find((i) => i.engine === e.id);
          const working =
            ["installing", "running", "queued"].includes(task?.status ?? "") ||
            starting === e.id;
          return (
            <div className="engine-row" key={e.id}>
              <div className="engine-icon">
                <AudioLines size={21} />
              </div>
              <div className="grow">
                <strong>{e.name}</strong>
                <p>
                  {working
                    ? "Downloading and testing the voice model…"
                    : e.available
                      ? `${e.supports_cloning ? "Voice cloning · " : ""}${e.languages.join(", ")}`
                      : (e.reason ?? "Not installed")}
                </p>
                <span className="license">{e.license}</span>
                {task?.error && <p className="job-error">{task.error}</p>}
              </div>
              {!e.available && ["kokoro", "qwen3"].includes(e.id) ? (
                <button
                  className="secondary"
                  disabled={working}
                  onClick={() => void install(e.id)}
                >
                  {working ? (
                    <LoaderCircle size={15} className="spin" />
                  ) : (
                    <Download size={15} />
                  )}{" "}
                  {working ? "Installing" : "Install model"}
                </button>
              ) : (
                <span
                  className={`status-pill ${e.available ? "completed" : ""}`}
                >
                  {e.available ? "Ready" : "Not available"}
                </span>
              )}
            </div>
          );
        })
      )}
      <p className="field-help">
        Models download to this PC. Installation can take several minutes and
        several gigabytes. An engine becomes ready only after a successful
        speech test.
      </p>
    </section>
  );
}

export function AnalyzerSettings() {
  const [url, setURL] = useState("");
  const [model, setModel] = useState("");
  const [key, setKey] = useState("");
  const [hasKey, setHasKey] = useState(false);
  const [clearKey, setClearKey] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    void api<{
      configured: boolean;
      url?: string;
      model?: string;
      has_api_key?: boolean;
    }>("/v1/admin/analyzer")
      .then((s) => {
        setURL(s.url ?? "");
        setModel(s.model ?? "");
        setHasKey(!!s.has_api_key);
      })
      .catch((e) => setError(e.message));
  }, []);
  async function save(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");
    try {
      const value = await api<{ has_api_key: boolean }>("/v1/admin/analyzer", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          url,
          model,
          ...(clearKey ? { api_key: "" } : key ? { api_key: key } : {}),
        }),
      });
      setHasKey(value.has_api_key);
      setKey("");
      setClearKey(false);
      setMessage(
        "Analysis model saved. You can now suggest a cast from a book’s studio.",
      );
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="panel">
      <h2>Cast analysis model</h2>
      <p className="muted">
        Connect an OpenAI-compatible local model server. A hosted service
        requires your explicit approval before a book is sent.
      </p>
      <form className="form-stack analyzer-form" onSubmit={(e) => void save(e)}>
        <label>
          API base URL
          <input
            type="url"
            required
            value={url}
            onChange={(e) => setURL(e.target.value)}
            placeholder="http://127.0.0.1:1234/v1"
          />
        </label>
        <label>
          Model ID
          <input
            required
            value={model}
            onChange={(e) => setModel(e.target.value)}
            placeholder="Model loaded in your local server"
          />
        </label>
        <label>
          API key{" "}
          <span className="field-help">
            {hasKey
              ? "A key is saved. Leave blank to keep it for this server."
              : "Optional for local servers."}
          </span>
          <input
            type="password"
            autoComplete="off"
            value={key}
            disabled={clearKey}
            onChange={(e) => setKey(e.target.value)}
          />
        </label>
        {hasKey && (
          <label className="checkbox">
            <input
              type="checkbox"
              checked={clearKey}
              onChange={(e) => setClearKey(e.target.checked)}
            />
            Remove saved key
          </label>
        )}
        <button className="secondary" disabled={busy}>
          <Save size={15} />
          Save analysis model
        </button>
        {message && (
          <p className="muted" role="status">
            {message}
          </p>
        )}
        {error && (
          <p className="job-error" role="alert">
            {error}
          </p>
        )}
      </form>
    </section>
  );
}
