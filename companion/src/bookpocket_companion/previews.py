"""Durable, protected voice auditions separate from book production."""
import json
from pathlib import Path
import shutil
import subprocess
import uuid
from fastapi import Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field
from .archiveio import file_digest
from .scheduler import WorkCancelled
from .store import canonical, now
from .worker import validate_wav


class PreviewRequest(BaseModel):
    request_id: uuid.UUID
    voice_id: str = Field(min_length=1, max_length=256)
    text: str = Field(min_length=1, max_length=1000)
    language: str = Field(default='en', min_length=1, max_length=16)


def register_previews(app, store, auth, get_voice, engines, config, scheduler):
    root = store.root / 'previews'
    root.mkdir(exist_ok=True)
    with store.db() as db:
        db.execute('CREATE TABLE IF NOT EXISTS voice_previews(id TEXT PRIMARY KEY,request_id TEXT UNIQUE,request TEXT,data TEXT,private TEXT,deleted INTEGER DEFAULT 0)')
        for row in db.execute('SELECT id,data FROM voice_previews WHERE deleted=0').fetchall():
            value = json.loads(row['data'])
            if value['status'] in {'queued', 'running'}:
                value.update(status='failed', error='Voice preview interrupted by companion restart; submit a new preview', finished_at=now())
                db.execute('UPDATE voice_previews SET data=? WHERE id=?', (canonical(value), row['id']))

    def cleanup(identity):
        for name in (identity + '-reference.wav', identity + '-raw.wav', identity + '-speech.wav'):
            path = root / name
            if path.resolve().parent != root.resolve(): continue
            try: path.unlink(missing_ok=True)
            except OSError: pass

    def read(identity):
        with store.db() as db: row = db.execute('SELECT * FROM voice_previews WHERE id=?', (identity,)).fetchone()
        if not row or row['deleted']: raise HTTPException(404, 'Voice preview not found')
        return json.loads(row['data'])

    def active(identity):
        with store.db() as db: row = db.execute('SELECT data,deleted FROM voice_previews WHERE id=?', (identity,)).fetchone()
        return row and not row['deleted'] and json.loads(row['data'])['status'] in {'queued', 'running'}

    def run(identity):
        destination = asset_id = None
        try:
            with scheduler.lease('preview', lambda: not active(identity)):
                with store.db() as db:
                    db.execute('BEGIN IMMEDIATE')
                    row = db.execute('SELECT * FROM voice_previews WHERE id=?', (identity,)).fetchone()
                    if not row or row['deleted']: return
                    value, body, private = json.loads(row['data']), json.loads(row['request']), json.loads(row['private'])
                    value.update(status='running', started_at=now(), error=None)
                    db.execute('UPDATE voice_previews SET data=? WHERE id=?', (canonical(value), identity))
                engine = engines[value['engine']]
                if not engine.info()['available']: raise ValueError('The selected voice engine is unavailable')
                voice = private['voice']
                if voice.get('reference'):
                    expected = root / (identity + '-reference.wav')
                    if Path(voice['reference']).resolve() != expected.resolve() or file_digest(expected) != private['reference_sha256']:
                        raise ValueError('The preview voice reference failed its checksum verification')
                raw, normalized = root / (identity + '-raw.wav'), root / (identity + '-speech.wav')
                engine.synthesize(body['text'], voice, raw, body['language'])
                subprocess.run([config.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(raw), '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', str(normalized)],
                               check=True, capture_output=True, timeout=120)
                duration = validate_wav(normalized)
                if duration > 300 or normalized.stat().st_size > 32 * 1024**2: raise ValueError('The voice preview exceeds its size or duration limit')
                asset_id = str(uuid.uuid4())
                destination = store.root / 'assets' / (asset_id + '.wav')
                asset = {'id': asset_id, 'segment_id': 'voice-preview:' + identity, 'media_type': 'audio/wav', 'duration': duration,
                         'sha256': file_digest(normalized), 'bytes': normalized.stat().st_size,
                         'url': '/v1/assets/' + asset_id, 'timings': [], 'narration_mode': 'single'}
                with store.db() as db:
                    db.execute('BEGIN IMMEDIATE')
                    row = db.execute('SELECT deleted FROM voice_previews WHERE id=?', (identity,)).fetchone()
                    if not row or row['deleted'] or scheduler.stopped.is_set(): return
                    normalized.replace(destination)
                    db.execute('INSERT INTO assets VALUES(?,?,?,?)', (asset_id, None, canonical(asset), str(destination)))
                    value.update(status='completed', finished_at=now(), asset=asset)
                    db.execute('UPDATE voice_previews SET data=? WHERE id=?', (canonical(value), identity))
        except WorkCancelled: pass
        except Exception as exc:
            with store.db() as db:
                row = db.execute('SELECT data,deleted FROM voice_previews WHERE id=?', (identity,)).fetchone()
                if row and not row['deleted']:
                    value = json.loads(row['data'])
                    value.update(status='failed', error=str(exc)[:1500], finished_at=now())
                    db.execute('UPDATE voice_previews SET data=? WHERE id=?', (canonical(value), identity))
        finally:
            cleanup(identity)
            if destination is not None:
                with store.db() as db:
                    if not db.execute('SELECT 1 FROM assets WHERE id=?', (asset_id,)).fetchone():
                        db.execute('INSERT OR IGNORE INTO deleted_asset_files VALUES(?)', (str(destination),))
                store.cleanup_deleted_assets()

    @app.post('/v1/voice-previews', status_code=202, dependencies=[Depends(auth)])
    def create(body: PreviewRequest):
        if not body.text.strip(): raise HTTPException(422, 'Enter some text to preview')
        payload = canonical(body.model_dump(mode='json'))
        # Inventory may backfill historical job provenance, so resolve it
        # outside the write transaction while retaining the retry fast path.
        with store.db() as db:
            previous = db.execute('SELECT data,request,deleted FROM voice_previews WHERE request_id=?', (str(body.request_id),)).fetchone()
        if previous:
            if previous['request'] != payload: raise HTTPException(409, 'This preview request ID was already used with different voice, text or language')
            if previous['deleted']: raise HTTPException(410, 'This preview was deleted; use a new request ID')
            return json.loads(previous['data'])
        voice = get_voice(body.voice_id)
        engine = engines.get(voice['engine'])
        if not engine or not engine.info()['available']: raise HTTPException(409, 'Install or start the selected voice engine first')
        if body.language not in engine.info()['languages']: raise HTTPException(422, 'The selected engine does not support this preview language')
        with store.db() as db:
            db.execute('BEGIN IMMEDIATE')
            previous = db.execute('SELECT data,request,deleted FROM voice_previews WHERE request_id=?', (str(body.request_id),)).fetchone()
            if previous:
                if previous['request'] != payload: raise HTTPException(409, 'This preview request ID was already used with different voice, text or language')
                if previous['deleted']: raise HTTPException(410, 'This preview was deleted; use a new request ID')
                return json.loads(previous['data'])
            if scheduler.stopped.is_set(): raise HTTPException(503, scheduler.stop_reason)
            pending = sum(json.loads(row[0])['status'] in {'queued', 'running'} for row in db.execute('SELECT data FROM voice_previews WHERE deleted=0'))
            if pending >= 4: raise HTTPException(409, 'Wait for an existing voice preview to finish before submitting another')
            identity = str(uuid.uuid4())
            private = {'voice': voice, 'reference_sha256': None}
            row = db.execute('SELECT reference,transcript FROM voices WHERE id=?', (body.voice_id,)).fetchone()
            if voice.get('kind') == 'clone' and not row: raise HTTPException(409, 'The selected voice was deleted before preview submission')
            if row:
                reference = Path(row['reference'])
                if reference.resolve().parent != (store.root / 'voices').resolve() or not reference.is_file(): raise HTTPException(409, 'The saved voice reference is unavailable')
                if reference.stat().st_size > 20 * 1024**2: raise HTTPException(409, 'The saved reference exceeds the preview limit')
                frozen = root / (identity + '-reference.wav')
                try:
                    shutil.copyfile(reference, frozen)
                    private['reference_sha256'] = file_digest(frozen)
                except BaseException: cleanup(identity); raise
                private['voice'] = {**voice, 'reference': str(frozen), 'transcript': row['transcript']}
            value = {'id': identity, 'voice_id': body.voice_id, 'voice_name': voice['name'], 'engine': voice['engine'],
                     'text': body.text, 'language': body.language, 'status': 'queued', 'created_at': now(), 'error': None}
            try: db.execute('INSERT INTO voice_previews VALUES(?,?,?,?,?,0)', (identity, str(body.request_id), payload, canonical(value), canonical(private)))
            except BaseException: cleanup(identity); raise
        try: scheduler.start_thread(lambda: run(identity), 'voice-preview')
        except Exception:
            with store.db() as db:
                value.update(status='failed', error='Unable to start voice preview; submit a new request', finished_at=now())
                db.execute('UPDATE voice_previews SET data=? WHERE id=?', (canonical(value), identity))
            cleanup(identity)
        return read(identity)

    @app.get('/v1/voice-previews/{identity}', dependencies=[Depends(auth)])
    def get(identity: str): return read(identity)

    @app.delete('/v1/voice-previews/{identity}', status_code=204, dependencies=[Depends(auth)])
    def delete(identity: str):
        with store.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT data,deleted FROM voice_previews WHERE id=?', (identity,)).fetchone()
            if not row: raise HTTPException(404, 'Voice preview not found')
            value = json.loads(row['data'])
            db.execute('UPDATE voice_previews SET deleted=1 WHERE id=?', (identity,))
            asset = value.get('asset')
            if asset:
                retained = any(asset['id'] in {a['id'] for a in json.loads(row[0]).get('assets', [])} for row in db.execute('SELECT data FROM jobs'))
                if not retained:
                    stored = db.execute('SELECT path FROM assets WHERE id=?', (asset['id'],)).fetchone()
                    if stored and Path(stored[0]).resolve().parent == (store.root / 'assets').resolve():
                        db.execute('DELETE FROM assets WHERE id=?', (asset['id'],))
                        db.execute('INSERT OR IGNORE INTO deleted_asset_files VALUES(?)', (stored[0],))
        # In-flight models own their frozen reference until the call returns.
        if value['status'] not in {'queued', 'running'}: cleanup(identity)
        store.cleanup_deleted_assets()
        return Response(status_code=204)

    with store.db() as db: abandoned = db.execute('SELECT id,data FROM voice_previews').fetchall()
    for row in abandoned:
        if json.loads(row['data'])['status'] not in {'queued', 'running'}: cleanup(row['id'])
