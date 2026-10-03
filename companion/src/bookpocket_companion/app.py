import base64
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import io
import ipaddress
import json
from pathlib import Path
import secrets
import sqlite3
import threading
import tempfile
import time
import uuid
import zipfile
from cryptography.fernet import Fernet
from fastapi import FastAPI, Depends, File, Form, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from . import __version__
from .engines import engines_for, ManagedEngine
from .models import Config, ExportRequest, GenerationRequest, PairRequest, validate_source_ranges, validate_narration_plan, job_metadata
from .publication import parse_book, extract_cover
from .store import Store, canonical, digest, now
from .worker import Worker
from .scheduler import WorkScheduler, WorkCancelled, WorkOwnershipUncertain
from .archiveio import MAX_ARCHIVE, require_disk


def create_app(config=None, engines=None, start_worker=True):
    config = config or Config()
    store = Store(config.data_dir)
    from .legacy import initialize as initialize_legacy
    initialize_legacy(store)
    engines = engines if engines is not None else engines_for(config)
    def prepare_work(kind):
        if kind != "render":
            for engine in engines.values():
                if hasattr(engine, "close"): engine.close()
    scheduler = WorkScheduler(prepare_work)
    worker = Worker(store, engines, config, scheduler)
    key_file = store.root / "pairing.key"
    if not key_file.exists(): key_file.write_bytes(Fernet.generate_key())
    cipher = Fernet(key_file.read_bytes())
    with store.db() as db:
        db.execute("UPDATE pairings SET encrypted_token=NULL WHERE expires<?", (time.time(),))
    attempts = defaultdict(deque)
    installs = {}
    observed_voice_names = {}
    install_lock = threading.Lock()
    project_lock = threading.Lock()

    @asynccontextmanager
    async def lifespan(app):
        if start_worker: worker.start()
        try: yield
        finally:
            scheduler.close()
            try: worker.close()
            finally: scheduler.join()

    app = FastAPI(title="Book Pocket Open", version=__version__, lifespan=lifespan)
    app.state.store, app.state.worker, app.state.config = store, worker, config
    app.state.scheduler = scheduler
    allowed_origins = {f"https://localhost:{config.port}", f"https://127.0.0.1:{config.port}"}
    allowed_origins |= {f"http://localhost:{config.studio_port}", f"http://127.0.0.1:{config.studio_port}"}
    if config.dev:
        allowed_origins |= {"http://localhost:8784", "http://127.0.0.1:8784", f"http://localhost:{config.port}", f"http://127.0.0.1:{config.port}"}
        app.add_middleware(CORSMiddleware, allow_origins=list(allowed_origins), allow_headers=["Authorization", "Content-Type", "Range"], allow_methods=["GET", "POST", "PUT", "DELETE"])

    def loopback(request):
        try: return ipaddress.ip_address(request.client.host).is_loopback
        except ValueError: return False

    def bearer(request):
        auth = request.headers.get("authorization", "")
        return auth[7:] if auth.startswith("Bearer ") else ""

    def is_admin(request):
        token = bearer(request)
        return bool(token and secrets.compare_digest(token, config.admin_token) and loopback(request)
                    and (not request.headers.get("origin") or request.headers["origin"] in allowed_origins))

    def admin(request: Request):
        if not is_admin(request): raise HTTPException(403, "Open the studio using the companion launcher on this PC")

    def auth(request: Request):
        if is_admin(request): return "admin"
        token = bearer(request)
        with store.db() as db:
            row = db.execute("SELECT id FROM devices WHERE token_hash=?", (digest(token),)).fetchone() if token else None
        if not row: raise HTTPException(401, "Pair this device or open the studio using the companion launcher")
        return row[0]

    @app.middleware("http")
    async def transport(request, call_next):
        # Never trust forwarded headers to establish peer identity or encryption.
        if not loopback(request) and request.url.scheme != "https":
            return JSONResponse({"detail": "Remote connections require HTTPS"}, status_code=403)
        if request.headers.get("origin") and request.headers["origin"] not in allowed_origins:
            return JSONResponse({"detail": "Unrecognized browser origin"}, status_code=403)
        if request.method in {"POST", "PUT"}:
            # Reject oversized multipart bodies before Starlette spools uploaded files.
            limit = MAX_ARCHIVE + 2 * 1024**2 if request.url.path == "/v1/projects/import" else (config.max_import_bytes + 2 * 1024 * 1024 if request.url.path == "/v1/books" else (22 * 1024 * 1024 if request.url.path == "/v1/voices" else 20 * 1024 * 1024))
            raw_length = request.headers.get("content-length")
            if request.headers.get("transfer-encoding"):
                return JSONResponse({"detail": "Send a bounded request with Content-Length"}, status_code=411)
            try: length = int(raw_length or "0")
            except ValueError: return JSONResponse({"detail": "Invalid Content-Length"}, status_code=400)
            if length < 0 or length > limit:
                return JSONResponse({"detail": "Request exceeds the upload limit"}, status_code=413)
        importing = request.method == "POST" and request.url.path == "/v1/projects/import"
        if importing:
            try:
                auth(request)  # Authenticate before multipart parsing can spool a large archive.
                if not raw_length: raise HTTPException(411, "Project uploads require Content-Length")
                require_disk(tempfile.gettempdir(), length)
            except HTTPException as exc: return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)
            except ValueError as exc: return JSONResponse({"detail": str(exc)}, status_code=507)
            if not project_lock.acquire(blocking=False):
                return JSONResponse({"detail": "Another project is importing; try again when it finishes"}, status_code=409)
        try: response = await call_next(request)
        finally:
            if importing: project_lock.release()
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        return response

    def require(table, identity):
        row = store.item(table, identity)
        if not row: raise HTTPException(404, f"{table.rstrip('s').capitalize()} not found")
        return row

    def limited(request):
        current = time.time()
        # Both a global and per-peer bound protect code guessing and memory use.
        for key, maximum in [("global", 100), (request.client.host, 12)]:
            queue = attempts[key]
            while queue and queue[0] < current - 60: queue.popleft()
            if len(queue) >= maximum: raise HTTPException(429, "Too many pairing attempts. Wait one minute")
            queue.append(current)
        if len(attempts) > 2048:
            for key in list(attempts):
                if key != "global" and (not attempts[key] or attempts[key][-1] < current - 60): del attempts[key]

    @app.get("/v1/health")
    def health(): return {"api_version": "1", "name": "Book Pocket Open", "version": __version__, "capabilities": ["source_ranges", "analysis_request_id", "source_ranges_cast"]}

    @app.get("/v1/admin/connection", dependencies=[Depends(admin)])
    def connection():
        result = {"url": config.public_url}
        if config.public_tls_mode == "pinned": result["certificate_sha256"] = config.certificate_sha256
        return result

    @app.post("/v1/admin/pairing-tickets", dependencies=[Depends(admin)])
    def ticket():
        identity, code, expires = str(uuid.uuid4()), secrets.token_hex(6).upper(), time.time() + 600
        with store.db() as db:
            db.execute("DELETE FROM tickets WHERE expires < ?", (time.time(),))
            db.execute("UPDATE pairings SET encrypted_token=NULL WHERE expires<?", (time.time(),))
            db.execute("INSERT INTO tickets(id,code_hash,expires) VALUES(?,?,?)", (identity, digest(code), expires))
        return {"id": identity, "code": code, "expires_at": datetime.fromtimestamp(expires, timezone.utc).isoformat()}

    @app.post("/v1/pairings")
    def pair(body: PairRequest, request: Request):
        limited(request)
        identity, poll = str(uuid.uuid4()), secrets.token_urlsafe(32)
        with store.db() as db:
            db.execute("BEGIN IMMEDIATE")
            ticket_row = db.execute("SELECT id FROM tickets WHERE code_hash=? AND used=0 AND expires>?", (digest(body.code.strip().upper()), time.time())).fetchone()
            if not ticket_row: raise HTTPException(400, "Pairing code is invalid, expired, or already used")
            db.execute("UPDATE tickets SET used=1 WHERE id=?", (ticket_row[0],))
            db.execute("INSERT INTO pairings(id,name,poll_hash,expires,status) VALUES(?,?,?,?,?)", (identity, body.device_name, digest(poll), time.time()+600, "pending"))
        return {"id": identity, "poll_token": poll, "status": "pending"}

    @app.get("/v1/admin/pairings", dependencies=[Depends(admin)])
    def pending():
        with store.db() as db:
            return {"pairings": [dict(r) for r in db.execute("SELECT id,name AS device_name,status,expires AS expires_at FROM pairings WHERE status='pending' AND expires>?", (time.time(),))]}

    @app.post("/v1/admin/pairings/{identity}/{action}", dependencies=[Depends(admin)])
    def decision(identity: str, action: str):
        if action not in {"approve", "reject"}: raise HTTPException(404, "Unknown action")
        with store.db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM pairings WHERE id=?", (identity,)).fetchone()
            if not row or row["expires"] < time.time(): raise HTTPException(404, "Pairing request expired")
            if row["status"] != "pending": raise HTTPException(409, "Pairing has already been resolved")
            if action == "reject": db.execute("UPDATE pairings SET status='rejected' WHERE id=?", (identity,))
            else:
                token, device_id = secrets.token_urlsafe(32), str(uuid.uuid4())
                db.execute("INSERT INTO devices VALUES(?,?,?,?)", (device_id, row["name"], digest(token), now()))
                db.execute("UPDATE pairings SET status='approved', device_id=?, encrypted_token=? WHERE id=?", (device_id, cipher.encrypt(token.encode()).decode(), identity))
        return {"status": "approved" if action == "approve" else "rejected"}

    @app.get("/v1/pairings/{identity}")
    def poll(identity: str, request: Request):
        with store.db() as db:
            row = db.execute("SELECT * FROM pairings WHERE id=?", (identity,)).fetchone()
            if not row or not secrets.compare_digest(row["poll_hash"], digest(bearer(request))): raise HTTPException(401, "Invalid pairing exchange")
            if row["expires"] < time.time():
                db.execute("UPDATE pairings SET encrypted_token=NULL WHERE id=?", (identity,))
                return {"status": "expired"}
            result = {"status": row["status"]}
            if row["status"] == "approved":
                device = db.execute("SELECT id FROM devices WHERE id=?", (row["device_id"],)).fetchone()
                if not device: return {"status": "rejected"}
                result.update(device_id=row["device_id"], device_token=cipher.decrypt(row["encrypted_token"].encode()).decode())
            return result

    @app.get("/v1/admin/devices", dependencies=[Depends(admin)])
    def devices():
        with store.db() as db: return {"devices": [dict(r) for r in db.execute("SELECT id,name,created_at FROM devices")]}

    @app.delete("/v1/admin/devices/{identity}", dependencies=[Depends(admin)])
    def revoke(identity: str):
        with store.db() as db: db.execute("DELETE FROM devices WHERE id=?", (identity,))
        return {"revoked": True}

    @app.delete("/v1/devices/current")
    def revoke_self(identity=Depends(auth)): return revoke(identity)

    @app.get("/v1/engines", dependencies=[Depends(auth)])
    def list_engines(): return {"engines": [e.info() for e in engines.values()]}

    @app.get("/v1/voices", dependencies=[Depends(auth)])
    def list_voices():
        voices = store.all("voices") + [v for e in engines.values() for v in e.voices()]
        names = {v["id"]: v["name"] for v in voices if v.get("name")}
        if any(observed_voice_names.get(identity) != name for identity, name in names.items()):
            # Resolve legacy names only from an actual available voice inventory.
            # Once captured, a job's name remains a historical snapshot.
            with store.db() as db:
                db.execute("BEGIN IMMEDIATE")
                for row in db.execute("SELECT id,data FROM jobs").fetchall():
                    job = json.loads(row["data"])
                    if not job.get("voice_name") and job.get("voice_id") in names:
                        job["voice_name"] = names[job["voice_id"]]
                        db.execute("UPDATE jobs SET data=? WHERE id=?", (canonical(job), row["id"]))
            observed_voice_names.update(names)
        return {"voices": voices}

    @app.get("/v1/voices/{identity}", dependencies=[Depends(auth)])
    def get_voice(identity: str):
        voice = next((v for v in list_voices()["voices"] if v["id"] == identity), None)
        if not voice: raise HTTPException(404, "Voice not found")
        return voice

    @app.post("/v1/voices", dependencies=[Depends(auth)])
    async def add_voice(name: str = Form(...), engine: str = Form(...), language: str = Form("en"), reference: UploadFile = File(...), transcript: str = Form(""), trim_start: float = Form(0), trim_end: float | None = Form(None)):
        if engine not in engines or not engines[engine].info()["supports_cloning"]: raise HTTPException(400, "This engine does not support importing voice references")
        if language not in engines[engine].info()["languages"]: raise HTTPException(400, "Choose a language supported by this voice engine")
        if not name.strip() or len(name) > 120: raise HTTPException(400, "Voice name must contain 1–120 characters")
        content = await reference.read(20 * 1024 * 1024 + 1)
        if len(content) > 20 * 1024 * 1024: raise HTTPException(413, "Voice reference exceeds 20 MiB")
        from .media import normalize_reference
        identity = str(uuid.uuid4())
        path = store.root / "voices" / (identity + ".wav")
        try: normalize_reference(content, path, config.ffmpeg, trim_start, trim_end)
        except Exception as exc: raise HTTPException(400, str(exc))
        voice = {"id": identity, "name": name.strip(), "engine": engine, "kind": "clone", "language": language, "created_at": now()}
        with store.db() as db: db.execute("INSERT INTO voices VALUES(?,?,?,?)", (identity, canonical(voice), str(path), transcript[:10000]))
        return voice

    @app.get("/v1/voices/{identity}/reference", dependencies=[Depends(auth)])
    def voice_reference(identity: str):
        row = require("voices", identity)
        return FileResponse(row["reference"], media_type="audio/wav")

    @app.delete("/v1/voices/{identity}", dependencies=[Depends(auth)])
    def delete_voice(identity: str):
        row = require("voices", identity)
        for j in store.all("jobs"):
            request = json.loads(store.item("jobs", j["id"])["request"])
            if j["status"] in {"running", "queued", "paused"} and (j["voice_id"] == identity or identity in request.get("cast", {}).values() or identity in {p["voice_id"] for p in request.get("narration_plan", [])}):
                raise HTTPException(409, "Cancel active jobs using this voice before deleting it")
        with store.db() as db: db.execute("DELETE FROM voices WHERE id=?", (identity,))
        Path(row["reference"]).unlink(missing_ok=True)
        return {"deleted": True}

    @app.get("/v1/books", dependencies=[Depends(auth)])
    def books(): return {"books": store.all("books")}

    @app.post("/v1/books", dependencies=[Depends(auth)])
    async def import_book(file: UploadFile = File(...), manifest: str | None = Form(None)):
        content = await file.read(config.max_import_bytes + 1)
        if len(content) > config.max_import_bytes: raise HTTPException(413, "Book exceeds 100 MiB")
        try: book = parse_book(content, file.filename or "book.epub")
        except Exception as exc: raise HTTPException(400, "Cannot import book: " + str(exc))
        if manifest:
            try:
                supplied = json.loads(manifest)
                if not isinstance(supplied, dict): raise ValueError("Manifest must be a Book JSON object")
                if supplied["source_sha256"] != book["source_sha256"] or supplied["chapters"] != book["chapters"]:
                    raise ValueError("Source spans differ from this companion's import format; use the returned manifest")
            except (ValueError, KeyError) as exc: raise HTTPException(409, str(exc))
        existing = store.item("books", book["id"])
        if existing: return json.loads(existing["data"])
        extension = ".epub" if (file.filename or "").lower().endswith(".epub") else ".txt"
        path = store.root / "books" / (book["id"] + extension)
        temporary = path.with_suffix(extension + "." + str(uuid.uuid4()) + ".tmp")
        temporary.write_bytes(content)
        temporary.replace(path)
        if extension == ".epub":
            try:
                cover = extract_cover(content)
                if cover:
                    (store.root / "books" / (book["id"] + ".jpg")).write_bytes(cover)
                    book["cover_url"] = f"/v1/books/{book['id']}/cover"
            except Exception:
                pass  # Missing or malformed optional artwork never prevents reading.
        with store.db() as db: db.execute("INSERT OR IGNORE INTO books VALUES(?,?,?)", (book["id"], canonical(book), str(path)))
        return book

    @app.get("/v1/books/{identity}", dependencies=[Depends(auth)])
    def get_book(identity: str): return json.loads(require("books", identity)["data"])

    @app.get("/v1/books/{identity}/source", dependencies=[Depends(auth)])
    def get_source(identity: str):
        row = require("books", identity)
        return FileResponse(row["source"], filename=Path(row["source"]).name)

    @app.get("/v1/books/{identity}/cover", dependencies=[Depends(auth)])
    def get_cover(identity: str):
        require("books", identity)
        path = store.root / "books" / (identity + ".jpg")
        if not path.exists(): raise HTTPException(404, "This book has no cover image")
        return FileResponse(path, media_type="image/jpeg")

    @app.delete("/v1/books/{identity}", dependencies=[Depends(auth)])
    def delete_book(identity: str):
        row = require("books", identity)
        if any(j["book_id"] == identity and j["status"] in {"queued", "running", "paused"} for j in store.all("jobs")):
            raise HTTPException(409, "Cancel this book's active jobs before deleting it")
        with store.db() as db: db.execute("DELETE FROM books WHERE id=?", (identity,))
        Path(row["source"]).unlink(missing_ok=True)
        (store.root / "books" / (identity + ".jpg")).unlink(missing_ok=True)
        return {"deleted": True}

    @app.post("/v1/jobs", status_code=202, dependencies=[Depends(auth)])
    def create_job(body: GenerationRequest):
        payload = body.model_dump()
        serialized = canonical(payload)
        with store.db() as db:
            existing = db.execute("SELECT request,data FROM jobs WHERE request_id=?", (body.request_id,)).fetchone()
        if existing:
            # New optional fields must not invalidate retries of jobs saved by an older version.
            try: previous_payload = GenerationRequest.model_validate_json(existing["request"]).model_dump()
            except ValueError: raise HTTPException(409, "request_id belongs to an imported or incompatible production")
            if canonical(previous_payload) != serialized: raise HTTPException(409, "request_id was already used with different settings")
            return job_metadata(json.loads(existing["data"]), previous_payload)
        if scheduler.stopped.is_set(): raise HTTPException(503, scheduler.stop_reason)
        book = get_book(body.book_id)
        valid = {s["id"] for c in book["chapters"] for s in c["segments"]}
        lengths = {s["id"]: len(s["text"]) for c in book["chapters"] for s in c["segments"]}
        if len(set(body.segment_ids)) != len(body.segment_ids) or not set(body.segment_ids) <= valid:
            raise HTTPException(400, "Select unique segments belonging to this book")
        if body.source_ranges and (body.cast or body.announce_chapters):
            raise HTTPException(422, "Source ranges cannot use whole-segment cast overrides or chapter announcements; use a clipped narration_plan")
        try: validate_source_ranges(payload["source_ranges"], body.segment_ids, lengths)
        except ValueError as exc: raise HTTPException(400, str(exc))
        if not set(body.cast) <= set(body.segment_ids): raise HTTPException(400, "Cast overrides must reference selected segments")
        try: validate_narration_plan(payload["narration_plan"], body.segment_ids, lengths, payload["source_ranges"])
        except ValueError as exc: raise HTTPException(400, str(exc))
        if body.engine not in engines or not engines[body.engine].info()["available"]: raise HTTPException(409, "Install or start the selected engine first")
        if body.language not in engines[body.engine].info()["languages"]: raise HTTPException(400, "Selected engine does not support this language")
        for identity in {body.voice_id, *body.cast.values(), *(p.voice_id for p in body.narration_plan)}:
            if get_voice(identity)["engine"] != body.engine: raise HTTPException(400, "All voices must belong to the selected engine")
        job = {"id": str(uuid.uuid4()), "book_id": body.book_id, "status": "queued", "engine": body.engine, "voice_id": body.voice_id,
               "voice_name": observed_voice_names.get(body.voice_id),
               "segment_ids": body.segment_ids, "completed_segments": 0, "total_segments": len(body.segment_ids), "created_at": now(),
               "started_at": None, "finished_at": None, "generation_seconds": 0.0, "error": None, "assets": []}
        if body.source_ranges: job["source_ranges"] = payload["source_ranges"]
        job = job_metadata(job, payload)
        try:
            with store.db() as db: db.execute("INSERT INTO jobs VALUES(?,?,?,?)", (job["id"], body.request_id, serialized, canonical(job)))
        except sqlite3.IntegrityError:
            return create_job(body)
        worker.wake.set()
        return job

    @app.get("/v1/jobs", dependencies=[Depends(auth)])
    def jobs():
        with store.db() as db: rows = db.execute("SELECT data,request FROM jobs ORDER BY rowid DESC").fetchall()
        return {"jobs": [job_metadata(json.loads(row["data"]), json.loads(row["request"])) for row in rows]}

    @app.get("/v1/jobs/{identity}", dependencies=[Depends(auth)])
    def get_job(identity: str):
        row = require("jobs", identity)
        return job_metadata(json.loads(row["data"]), json.loads(row["request"]))

    @app.post("/v1/jobs/{identity}/{action}", dependencies=[Depends(auth)])
    def action_job(identity: str, action: str):
        transitions = {"cancel": ({"queued", "running", "paused", "failed"}, "cancelled"), "pause": ({"queued", "running"}, "paused"),
                       "resume": ({"paused"}, "queued"), "retry": ({"failed", "cancelled"}, "queued")}
        if action not in transitions: raise HTTPException(404, "Unknown action")
        require("jobs", identity)
        before, after = transitions[action]
        result = worker.update(identity, lambda j: j.update(status=after, error=None, finished_at=now() if after == "cancelled" else None), before)
        if not result: raise HTTPException(409, "This action is not available for the current job state")
        worker.wake.set()
        return get_job(identity)

    @app.get("/v1/assets/{identity}", dependencies=[Depends(auth)])
    def get_asset(identity: str):
        row = require("assets", identity)
        asset = json.loads(row["data"])
        if not Path(row["path"]).exists(): raise HTTPException(410, "Audio file is missing; retry generation")
        return FileResponse(row["path"], media_type=asset["media_type"], headers={"ETag": '"'+asset["sha256"]+'"', "X-Content-SHA256": asset["sha256"]})

    # Register before the generic job action route to avoid /export being consumed as an action.
    @app.post("/v1/jobs/{identity}/export", dependencies=[Depends(auth)])
    def export(identity: str, body: ExportRequest):
        from .media import export_job
        job = get_job(identity)
        if job["status"] != "completed": raise HTTPException(409, "Finish generation before exporting")
        try: return export_job(store, job, body.format, config.ffmpeg, body.include_voice_references)
        except Exception as exc: raise HTTPException(400, "Export failed: " + str(exc))
    export_route = app.router.routes.pop()
    generic_index = next(i for i, route in enumerate(app.router.routes) if getattr(route, "path", "") == "/v1/jobs/{identity}/{action}")
    app.router.routes.insert(generic_index, export_route)

    @app.post("/v1/admin/engines/{identity}/install", dependencies=[Depends(admin)])
    def install(identity: str):
        engine = engines.get(identity)
        if not isinstance(engine, ManagedEngine): raise HTTPException(400, "Only managed engines can be installed here")
        with install_lock:
            if scheduler.stopped.is_set(): raise HTTPException(503, scheduler.stop_reason)
            if any(v["status"] in {"queued", "running"} for v in installs.values()): raise HTTPException(409, "An engine installation is already queued or running")
            installs[identity] = {"engine": identity, "status": "queued", "error": None, "created_at": now(), "started_at": None}
        def run_install():
            try:
                with scheduler.lease("install"):
                    installs[identity].update(status="running", started_at=now())
                    engine.install(cancel_event=scheduler.stopped)
                    if scheduler.stopped.is_set(): raise WorkCancelled("Installation stopped during companion shutdown")
                    installs[identity].update(status="completed", finished_at=now())
            except (WorkCancelled, WorkOwnershipUncertain):
                installs[identity].update(status="failed", finished_at=now(), error=scheduler.stop_reason)
            except Exception:
                installs[identity].update(status="failed", finished_at=now(), error="Installation failed. See the engine install log in your local data folder")
        try: scheduler.start_thread(run_install, "engine-install")
        except Exception:
            installs[identity].update(status="failed", finished_at=now(), error="Unable to start installation worker; retry installation")
        return dict(installs[identity])

    @app.get("/v1/admin/engines/installations", dependencies=[Depends(admin)])
    def installations(): return {"installations": list(installs.values())}

    @app.post("/v1/projects/import", dependencies=[Depends(auth)])
    def project_import(file: UploadFile = File(...)):
        from .project import import_project
        file.file.seek(0, 2)
        if file.file.tell() > MAX_ARCHIVE: raise HTTPException(413, "Project exceeds the 16 GiB import limit")
        file.file.seek(0)
        try:
            with zipfile.ZipFile(file.file) as archive:
                legacy = "legacy.json" in archive.namelist()
            file.file.seek(0)
            if legacy:
                from .legacy import import_legacy
                return import_legacy(store, file.file, config.ffmpeg)
            return import_project(store, file.file)
        except Exception as exc: raise HTTPException(400, "Cannot import project: " + str(exc))

    @app.get("/v1/legacy-recordings", dependencies=[Depends(auth)])
    def legacy_recordings(book_id: str | None = None):
        with store.db() as db:
            rows = db.execute("SELECT data FROM legacy_recordings" + (" WHERE book_id=?" if book_id else ""), (book_id,) if book_id else ()).fetchall()
        return {"recordings": [json.loads(r[0]) for r in rows]}

    @app.get("/v1/pronunciations", dependencies=[Depends(auth)])
    def imported_pronunciations():
        with store.db() as db: row = db.execute("SELECT value FROM preferences WHERE key='pronunciation_rules'").fetchone()
        return {"pronunciation_rules": json.loads(row[0]) if row else []}

    from .casting import register_casting
    register_casting(app, store, auth, admin, get_book, scheduler)

    if config.studio_dir and config.studio_dir.is_dir():
        app.mount("/", StaticFiles(directory=config.studio_dir, html=True), name="studio")
    return app
