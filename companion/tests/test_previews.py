"""Explicit synthetic transport fixtures test persistence, not voice quality."""
import io
import json
import shutil
import threading
import time
import uuid
import wave
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config
from bookpocket_companion.store import canonical, now


class Engine:
    id, version = 'fixture', 'preview-fixture-1'
    def __init__(self): self.entered, self.release = threading.Event(), threading.Event(); self.calls = []
    def info(self): return {'available': True, 'languages': ['en'], 'supports_cloning': True}
    def voices(self): return []
    def synthesize(self, text, voice, output, language):
        self.calls.append((text, voice.copy()))
        self.entered.set()
        assert self.release.wait(5)
        with wave.open(str(output), 'wb') as audio:
            audio.setparams((1, 2, 24000, 0, 'NONE', 'not compressed')); audio.writeframes(b'\0\0' * 2400)


@pytest.fixture
def preview(tmp_path):
    if not shutil.which('ffmpeg'): pytest.skip('Real WAV normalization boundary requires FFmpeg')
    engine = Engine()
    cfg = Config(data_dir=tmp_path, admin_token='fixture-admin', dev=True)
    app = create_app(cfg, engines={'fixture': engine}, start_worker=False)
    client = TestClient(app, client=('127.0.0.1', 1234), headers={'Authorization': 'Bearer fixture-admin'})
    reference = tmp_path / 'voices' / 'fixture.wav'
    with wave.open(str(reference), 'wb') as wav:
        wav.setparams((1, 2, 24000, 0, 'NONE', 'not compressed')); wav.writeframes(b'\0\0' * 24000)
    voice = {'id': 'fixture-voice', 'name': 'Fixture voice', 'engine': 'fixture', 'kind': 'clone', 'language': 'en', 'created_at': now()}
    with app.state.store.db() as db: db.execute('INSERT INTO voices VALUES(?,?,?,?)', (voice['id'], canonical(voice), str(reference), 'Private fixture transcript'))
    body = {'request_id': str(uuid.uuid4()), 'voice_id': voice['id'], 'text': 'An original voice audition.', 'language': 'en'}
    yield app, client, engine, cfg, body
    engine.release.set()
    app.state.scheduler.join()


def terminal(client, job):
    for _ in range(100):
        value = client.get('/v1/voice-previews/' + job['id']).json()
        if value['status'] not in {'queued', 'running'}: return value
        time.sleep(.02)
    pytest.fail('Preview fixture did not finish')


def test_preview_freezes_reference_deduplicates_and_deletes_without_book_jobs(preview):
    app, client, engine, _, body = preview
    response = client.post('/v1/voice-previews', json=body)
    assert response.status_code == 202 and engine.entered.wait(3)
    job = response.json()
    assert client.post('/v1/voice-previews', json=body).json()['id'] == job['id']
    assert client.post('/v1/voice-previews', json={**body, 'text': 'Changed source.'}).status_code == 409
    assert client.delete('/v1/voices/' + body['voice_id']).status_code == 409
    assert 'Private fixture transcript' not in response.text and 'reference' not in response.text
    assert not app.state.store.all('books') and not app.state.store.all('jobs')
    assert engine.calls[0][1]['reference'].endswith(job['id'] + '-reference.wav')
    engine.release.set()
    complete = terminal(client, job)
    assert complete['status'] == 'completed' and complete['asset']['duration'] == .1
    audio = client.get(complete['asset']['url'])
    assert audio.content[:4] == b'RIFF' and audio.headers['x-content-sha256'] == complete['asset']['sha256']
    assert not list((app.state.store.root / 'previews').glob('*.wav'))
    assert client.delete('/v1/voice-previews/' + job['id']).status_code == 204
    assert client.delete('/v1/voice-previews/' + job['id']).status_code == 204
    assert client.get('/v1/voice-previews/' + job['id']).status_code == 404
    assert client.get(complete['asset']['url']).status_code == 404
    assert client.post('/v1/voice-previews', json=body).status_code == 410
    assert client.get('/v1/voices/' + body['voice_id']).status_code == 200


def test_deleted_inflight_preview_cannot_publish_audio(preview):
    app, client, engine, _, body = preview
    job = client.post('/v1/voice-previews', json=body).json()
    assert engine.entered.wait(3)
    assert client.delete('/v1/voice-previews/' + job['id']).status_code == 204
    engine.release.set()
    app.state.scheduler.join()
    assert not app.state.store.all('assets')
    assert not list((app.state.store.root / 'previews').glob('*.wav'))
    assert client.post('/v1/voice-previews', json=body).status_code == 410


def test_preview_restart_and_known_retry_need_no_current_voice(preview):
    app, client, engine, cfg, body = preview
    engine.release.set()
    job = terminal(client, client.post('/v1/voice-previews', json=body).json())
    assert client.delete('/v1/voices/' + body['voice_id']).status_code == 200
    assert client.post('/v1/voice-previews', json=body).json() == job
    with app.state.store.db() as db:
        unfinished = {**job, 'id': 'interrupted-fixture', 'status': 'running'}
        db.execute('INSERT INTO voice_previews VALUES(?,?,?,?,?,0)', (unfinished['id'], str(uuid.uuid4()), canonical(body), canonical(unfinished), '{}'))
    reconstructed = create_app(cfg, engines={}, start_worker=False)
    other = TestClient(reconstructed, client=('127.0.0.1', 1234), headers=client.headers)
    failed = other.get('/v1/voice-previews/interrupted-fixture').json()
    assert failed['status'] == 'failed' and 'restart' in failed['error']
    assert other.post('/v1/voice-previews', json=body).json() == job
