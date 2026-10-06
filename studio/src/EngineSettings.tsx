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
                  {task?.status === "queued"
                    ? "Waiting for the current PC task to finish…"
                    : working
                      ? "Downloading and testing the voice model…"
                      : e.available
                        ? `${e.supports_cloning ? "Voice cloning · " : ""}${e.languages.join(", ")}`
                        : (e.reason ?? "Not installed")}
                </p>
                <span className="license">{e.license}</span>
                {task?.error && <p className="job-error">{task.error}</p>}
              </div>
              {!e.available &&
              ["kokoro", "qwen3", "omnivoice"].includes(e.id) ? (
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
                  {task?.status === "queued"
                    ? "Queued"
                    : working
                      ? "Installing"
                      : "Install model"}
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
  const [provider, setProvider] = useState("openai");
  const [cliPath, setCLIPath] = useState("");
  const [url, setURL] = useState("");
  const [model, setModel] = useState("");
  const [outputLimit, setOutputLimit] = useState(4096);
  const [key, setKey] = useState("");
  const [hasKey, setHasKey] = useState(false);
  const [clearKey, setClearKey] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [readinessError, setReadinessError] = useState("");
  useEffect(() => {
    void api<{
      configured: boolean;
      url?: string;
      model?: string;
      has_api_key?: boolean;
      max_output_tokens?: number;
      provider?: string;
      cli_path?: string;
      readiness_error?: string;
    }>("/v1/admin/analyzer")
      .then((s) => {
        setProvider(s.provider ?? "openai");
        setCLIPath(s.cli_path ?? "");
        setURL(s.url ?? "");
        setModel(s.model ?? "");
        setHasKey(!!s.has_api_key);
        setOutputLimit(s.max_output_tokens ?? 4096);
        setReadinessError(s.readiness_error ?? "");
      })
      .catch((e) => setError(e.message));
  }, []);
  async function save(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");
    try {
      const value = await api<{
        has_api_key: boolean;
        readiness_error?: string;
      }>("/v1/admin/analyzer", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          provider,
          url: provider === "antigravity" ? "" : url,
          model,
          ...(provider === "antigravity" ? { cli_path: cliPath || null } : {}),
          max_output_tokens: outputLimit,
          ...(provider === "antigravity"
            ? { api_key: "" }
            : clearKey
              ? { api_key: "" }
              : key
                ? { api_key: key }
                : {}),
        }),
      });
      setHasKey(value.has_api_key);
      setKey("");
      setClearKey(false);
      setReadinessError(value.readiness_error ?? "");
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
        Choose who identifies the speakers. Google analysis uses your PC’s
        Antigravity sign-in; OmniVoice still creates the audio on your PC.
      </p>
      <form className="form-stack analyzer-form" onSubmit={(e) => void save(e)}>
        <label>
          Analysis provider
          <select
            value={provider}
            onChange={(e) => {
              const next = e.target.value;
              setProvider(next);
              setMessage("");
              if (next === "antigravity" && provider !== next)
                setModel("gemini-3.8-flash-high");
            }}
          >
            <option value="antigravity">Google · Antigravity CLI</option>
            <option value="openai">OpenAI-compatible server</option>
          </select>
        </label>
        {provider === "antigravity" ? (
          <p className="field-help">
            Install Antigravity CLI and sign in with your Google AI Pro account
            once on this PC. No API key is used. Chapter text goes to Google
            only when you allow hosted analysis. Your plan’s usage limits apply.
          </p>
        ) : (
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
        )}
        <label>
          Model ID
          <input
            required
            readOnly={provider === "antigravity"}
            value={model}
            onChange={(e) => setModel(e.target.value)}
            placeholder={
              provider === "antigravity"
                ? "gemini-3.8-flash-high"
                : "Model loaded in your server"
            }
          />
        </label>
        {provider !== "antigravity" && (
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
        )}
        <details>
          <summary>Advanced model settings</summary>
          {provider === "antigravity" && (
            <label>
              Antigravity executable
              <input
                value={cliPath}
                onChange={(e) => setCLIPath(e.target.value)}
                placeholder="Automatic · agy"
              />
              <span className="field-help">
                Leave blank to find the installed CLI. Use an absolute
                executable path for a custom installation.
              </span>
            </label>
          )}
          <label>
            Maximum response tokens
            <input
              type="number"
              min="256"
              max="16384"
              step="1"
              required
              value={outputLimit}
              onChange={(e) => setOutputLimit(Number(e.target.value))}
            />
            <span className="field-help">
              Increase this if analysis stops before finishing its answer. Keep
              enough room in your model’s context for the book passages.
            </span>
          </label>
        </details>
        {hasKey && provider !== "antigravity" && (
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
        {provider === "antigravity" && readinessError && (
          <p className="job-error" role="alert">
            {readinessError}
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
