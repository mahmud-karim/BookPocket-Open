"""Recording deletion, exact word metadata repair and pronunciation concurrency."""
import json
import io
from pathlib import Path
import re
import shutil
import wave
import zipfile
import numpy as np
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion.app import create_app
from bookpocket_companion.alignment import WordAligner, MODEL_FILES, MODEL_HASHES, MODEL_REVISION
from bookpocket_companion.ctc_alignment import force_align, lexical_words
from bookpocket_companion.models import Config
from bookpocket_companion.store import canonical, now
from bookpocket_companion.worker import Worker
from bookpocket_companion.worker import spoken_mapping, word_timings


class FixtureEngine:
    id, version = 'fixture', 'recording-updates-1'
    def __init__(self): self.hook = None
    def info(self): return {'id': self.id, 'available': True, 'languages': ['en'], 'name': 'Explicit test fixture'}
    def voices(self): return [{'id': 'fixture:narrator', 'engine': self.id, 'name': 'Fixture', 'kind': 'preset', 'language': 'en', 'created_at': now()}]
    def synthesize(self, text, voice, output, language):
        with wave.open(str(output), 'wb') as audio:
            audio.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
            audio.writeframes(b'\0\0' * 2400)
        if self.hook: self.hook()


class FixtureAligner:
    """Only used to test state/offset mapping; not an acoustic quality claim."""
    def __init__(self): self.hook = None
    def ready(self): return True
    def close(self): pass
    def align(self, path, text, language='en', start=0, end=None):
        if self.hook: self.hook()
        tokens = list(re.finditer(r"[^\W_]+", text))
        return {'words': [{'text': token.group(), 'start': i * .01, 'end': (i + 1) * .01} for i, token in enumerate(tokens)]}


@pytest.fixture
def recording(tmp_path):
    if not shutil.which('ffmpeg'): pytest.skip('ffmpeg needed to verify actual WAV publication boundary')
    engine = FixtureEngine()
    config = Config(data_dir=tmp_path, admin_token='fixture-admin', dev=True)
    app = create_app(config, engines={'fixture': engine}, start_worker=False)
    client = TestClient(app, client=('127.0.0.1', 3456), headers={'Authorization': 'Bearer fixture-admin'})
    book = client.post('/v1/books', files={'file': ('original.txt', 'Hello 🧭 Kyon. Next sentence.')}).json()
    request = {'request_id': 'original-request', 'book_id': book['id'], 'segment_ids': [s['id'] for c in book['chapters'] for s in c['segments']],
               'engine': 'fixture', 'voice_id': 'fixture:narrator', 'pronunciation_rules': [{'term': 'Kyon', 'replacement': 'Key on', 'enabled': True}]}
    job = client.post('/v1/jobs', json=request).json()
    app.state.worker.run(job['id'])
    return app, client, engine, config, request, client.get('/v1/jobs/' + job['id']).json()


def test_shared_recording_deletion_keeps_other_take_and_tombstones_retries(recording):
    app, client, _, config, request, original = recording
    second = client.post('/v1/jobs', json={**request, 'request_id': 'other-request'}).json()
    app.state.worker.run(second['id'])
    second = client.get('/v1/jobs/' + second['id']).json()
    assert [a['id'] for a in second['assets']] == [a['id'] for a in original['assets']]
    paths = [Path(app.state.store.item('assets', a['id'])['path']) for a in original['assets']]
    exported = client.post('/v1/jobs/' + original['id'] + '/export', json={'format': 'project'}).json()
    assert client.delete('/v1/jobs/' + original['id']).status_code == 204
    assert client.delete('/v1/jobs/' + original['id']).status_code == 204
    assert all(p.exists() for p in paths)
    assert client.get('/v1/jobs/' + original['id']).status_code == 404
    assert client.get('/v1/jobs/' + second['id']).json()['status'] == 'completed'
    assert client.post('/v1/jobs', json=request).status_code == 410
    assert client.delete('/v1/jobs/' + second['id']).status_code == 204
    assert not any(p.exists() for p in paths)
    assert client.get(exported['url']).status_code == 200
    restarted = create_app(config, engines={}, start_worker=False)
    other = TestClient(restarted, client=('127.0.0.1', 3456), headers=client.headers)
    assert other.delete('/v1/jobs/' + original['id']).status_code == 204
    assert other.post('/v1/jobs', json=request).status_code == 410
    assert other.get('/v1/books/' + request['book_id']).status_code == 200


def test_delete_inflight_generation_never_publishes_or_recreates_take(recording):
    app, client, engine, _, request, _ = recording
    job = client.post('/v1/jobs', json={**request, 'request_id': 'delete-during-render', 'take_id': 'a06030c2-672b-4a5b-8491-d45234615480'}).json()
    before = set(a['id'] for a in app.state.store.all('assets'))
    engine.hook = lambda: client.delete('/v1/jobs/' + job['id'])
    app.state.worker.run(job['id'])
    assert client.get('/v1/jobs/' + job['id']).status_code == 404
    assert set(a['id'] for a in app.state.store.all('assets')) == before
    assert not list((app.state.store.root / 'assets').glob('.*'))


def test_alignment_preserves_hash_source_boundaries_and_updates_all_cached_takes(recording):
    app, client, _, _, request, original = recording
    other = client.post('/v1/jobs', json={**request, 'request_id': 'shared-alignment'}).json()
    app.state.worker.run(other['id'])
    old = original['assets'][0]
    old['alignment_error'] = 'Earlier acoustic alignment was unavailable'
    app.state.worker.update(original['id'], lambda j: j.update(assets=original['assets']))
    content = client.get(old['url']).content
    app.state.worker.aligner = FixtureAligner()
    response = client.post('/v1/jobs/' + original['id'] + '/align')
    assert response.status_code == 202
    assert response.json()['alignment_status'] == 'queued'
    assert client.post('/v1/jobs/' + original['id'] + '/align').json()['alignment_status'] == 'queued'
    app.state.worker.run_alignment(original['id'])
    repaired = client.get('/v1/jobs/' + original['id']).json()
    shared = client.get('/v1/jobs/' + other['id']).json()
    assert repaired['alignment_status'] == 'completed'
    new = repaired['assets'][0]
    assert new['timings'] == shared['assets'][0]['timings']
    assert new['timings'] == json.loads(app.state.store.item('assets', new['id'])['data'])['timings']
    assert new['alignment'] == 'word' and new['source_timings'] == old['timings']
    assert 'alignment_error' not in new
    assert new['sha256'] == old['sha256'] and new['bytes'] == old['bytes'] and new['id'] == old['id']
    assert client.get(new['url']).content == content
    assert [(t['start_offset'], t['end_offset']) for t in new['timings'][:3]] == [(0, 5), (8, 12), (8, 12)]
    assert new['source_timings'][0]['end_offset'] == 13  # punctuation retained for exact wider-asset trimming
    assert client.post('/v1/jobs/' + original['id'] + '/align').json()['alignment_status'] == 'completed'


def test_alignment_failure_is_honest_and_delete_during_alignment_cannot_publish(recording):
    app, client, _, _, _, original = recording
    fixture = FixtureAligner()
    app.state.worker.aligner = fixture
    def fail(): raise ValueError('Speech did not match this transcript')
    fixture.hook = fail
    client.post('/v1/jobs/' + original['id'] + '/align')
    app.state.worker.run_alignment(original['id'])
    failed = client.get('/v1/jobs/' + original['id']).json()
    assert failed['alignment_status'] == 'failed' and 'did not match' in failed['alignment_error']
    assert failed['assets'][0]['alignment'] == 'sentence'
    assert failed['assets'][0]['timings'] == original['assets'][0]['timings']
    fixture.hook = lambda: client.delete('/v1/jobs/' + original['id'])
    client.post('/v1/jobs/' + original['id'] + '/align')
    app.state.worker.run_alignment(original['id'])
    assert client.get('/v1/jobs/' + original['id']).status_code == 404
    assert not app.state.store.all('assets')


def test_durable_alignment_recovers_without_resetting_recording(recording, monkeypatch):
    app, client, _, config, _, original = recording
    app.state.worker.update(original['id'], lambda j: j.update(alignment_status='running'))
    restarted = create_app(config, engines={}, start_worker=False)
    monkeypatch.setattr(Worker, 'loop', lambda worker: worker.stop.set())
    restarted.state.worker.start()
    restarted.state.worker.close()
    value = json.loads(restarted.state.store.item('jobs', original['id'])['data'])
    assert value['alignment_status'] == 'queued' and value['status'] == 'completed'
    assert value['assets'] == original['assets']


def test_pronunciation_revision_conflicts_keep_book_and_existing_audio(recording):
    _, client, _, _, request, original = recording
    assert client.get('/v1/pronunciations').json() == {'pronunciation_rules': [], 'revision': 0}
    correction = {'pronunciation_rules': [{'term': 'Kyon', 'replacement': 'Key on', 'enabled': True}], 'expected_revision': 0}
    changed = client.put('/v1/pronunciations', json=correction)
    assert changed.status_code == 200 and changed.json()['revision'] == 1
    assert client.put('/v1/pronunciations', json=correction).status_code == 409
    assert client.put('/v1/pronunciations', json={**correction, 'pronunciation_rules': [{'term': '   ', 'replacement': 'word'}], 'expected_revision': 1}).status_code == 422
    assert client.put('/v1/pronunciations', json={**correction, 'pronunciation_rules': [{'term': 'Kyon', 'replacement': 'a'}, {'term': 'KYON', 'replacement': 'b'}], 'expected_revision': 1}).status_code == 422
    assert client.get('/v1/jobs/' + original['id']).json()['assets'] == original['assets']
    assert 'Hello 🧭 Kyon.' in client.get('/v1/books/' + request['book_id']) .json()['chapters'][0]['segments'][0]['text']
    assert client.put('/v1/pronunciations', json={'pronunciation_rules': [], 'expected_revision': 1}).json() == {'pronunciation_rules': [], 'revision': 2}


def test_ctc_repeated_labels_require_real_blank_and_complete_transcript():
    # Acoustic frames predict A, blank, A, B. Distinct source letters must not
    # collapse or share fabricated evenly spaced durations.
    emissions = np.log(np.array([[.01, .98, .01], [.98, .01, .01], [.01, .98, .01], [.01, .01, .98]], dtype=np.float32))
    spans = force_align(emissions, [1, 1, 2])
    assert [(start, end) for start, end, _ in spans] == [(0, 1), (2, 3), (3, 4)]
    with pytest.raises(ValueError, match='too short'): force_align(emissions[:2], [1, 1, 2])
    with pytest.raises(ValueError, match='Invalid'): force_align(np.full((2, 3), np.nan), [1])


def test_english_normalization_preserves_original_unicode_number_and_name_spans():
    words = lexical_words("🧭 Café Kyon’s 21 cats.")
    assert words == [(2, 6, 'CAFE'), (7, 13, "KYON'S"), (14, 16, 'TWENTY ONE'), (17, 21, 'CATS')]
    assert lexical_words('2.5 12,345') == [(0, 3, 'TWO POINT FIVE'), (4, 10, 'TWELVE THOUSAND THREE HUNDRED FORTY FIVE')]
    with pytest.raises(ValueError, match='English'): lexical_words('こんにちは')


def test_alignment_installer_requests_every_pinned_file_and_rejects_failed_probe(tmp_path, monkeypatch):
    from bookpocket_companion import alignment
    aligner = WordAligner(Config(data_dir=tmp_path))
    aligner.python.parent.mkdir(parents=True)
    aligner.python.write_bytes(b'explicit-interpreter-fixture')
    commands = []
    def run(command, **kwargs):
        commands.append(command)
        if 'download' in command:
            model = Path(command[command.index('--local-dir') + 1])
            model.mkdir(parents=True)
            for name in MODEL_FILES: (model / name).write_bytes(b'explicit-download-fixture')
        else: raise RuntimeError('Model probe failed')
    monkeypatch.setattr(alignment, 'run_setup', run)
    monkeypatch.setattr(aligner, 'verify_model', lambda: None)
    with pytest.raises(RuntimeError, match='probe failed'): aligner.install()
    assert commands[0][3:3 + len(MODEL_FILES)] == list(MODEL_FILES)
    assert '--include' not in commands[0]
    assert not (aligner.root / 'ready.json').exists()


def test_model_integrity_rejects_tampered_pinned_weight_even_with_ready_marker(tmp_path):
    aligner = WordAligner(Config(data_dir=tmp_path))
    aligner.python.parent.mkdir(parents=True)
    aligner.python.write_bytes(b'interpreter-fixture')
    aligner.model.mkdir(parents=True)
    for name in MODEL_FILES: (aligner.model / name).write_bytes(b'tampered-fixture')
    (aligner.root / 'ready.json').write_text(json.dumps({'revision': MODEL_REVISION, 'validated_model': True,
                                                       'file_hashes': {name: value[1] for name, value in MODEL_HASHES.items()}}))
    assert not aligner.ready()


def test_delayed_submission_cannot_resurrect_a_concurrently_created_then_deleted_take(recording, monkeypatch):
    app, client, engine, _, request, _ = recording
    payload = {**request, 'request_id': 'delayed-new-request'}
    original_info = engine.info
    deleted = []
    def concurrent_submission():
        monkeypatch.setattr(engine, 'info', original_info)
        accepted = client.post('/v1/jobs', json=payload)
        assert accepted.status_code == 202
        identity = accepted.json()['id']
        assert client.delete('/v1/jobs/' + identity).status_code == 204
        deleted.append(identity)
        return original_info()
    monkeypatch.setattr(engine, 'info', concurrent_submission)
    assert client.post('/v1/jobs', json=payload).status_code == 410
    assert len(deleted) == 1
    assert not any(j['id'] in deleted for j in app.state.store.all('jobs'))


def test_open_download_file_deletion_is_durable_and_retried(recording, monkeypatch):
    app, client, _, _, _, job = recording
    path = Path(app.state.store.item('assets', job['assets'][0]['id'])['path'])
    real_unlink = Path.unlink
    def locked(value, *args, **kwargs):
        if value == path: raise PermissionError('Explicit Windows download-handle fixture')
        return real_unlink(value, *args, **kwargs)
    monkeypatch.setattr(Path, 'unlink', locked)
    assert client.delete('/v1/jobs/' + job['id']).status_code == 204
    assert path.exists() and app.state.store.item('assets', job['assets'][0]['id']) is None
    with app.state.store.db() as db: assert db.execute('SELECT COUNT(*) FROM deleted_asset_files').fetchone()[0] == 1
    monkeypatch.setattr(Path, 'unlink', real_unlink)
    app.state.store.cleanup_deleted_assets()
    assert not path.exists()
    with app.state.store.db() as db: assert db.execute('SELECT COUNT(*) FROM deleted_asset_files').fetchone()[0] == 0


def test_portable_import_rejects_forged_source_trim_boundaries(recording):
    _, client, _, _, _, job = recording
    exported = client.post('/v1/jobs/' + job['id'] + '/export', json={'format': 'project'}).json()
    data = client.get(exported['url']).content
    original = zipfile.ZipFile(io.BytesIO(data))
    manifest = json.loads(original.read('project.json'))
    manifest['job']['assets'][0]['source_timings'][0]['end_offset'] = 10000
    content = io.BytesIO()
    with zipfile.ZipFile(content, 'w') as archive:
        for name in original.namelist(): archive.writestr(name, json.dumps(manifest) if name == 'project.json' else original.read(name))
    response = client.post('/v1/projects/import', files={'file': ('invalid-project.zip', content.getvalue())})
    assert response.status_code == 400 and 'timings' in response.json()['detail']


def test_partial_model_token_track_never_claims_complete_word_alignment():
    text, mapping = spoken_mapping('Hello Kyon.', [])
    partial = {'words': [{'text': 'Kyon', 'start': .2, 'end': .5}]}
    assert word_timings(partial, text, mapping, 0, 0, 1, require_complete=True) is None
    assert word_timings({'words': [{'text': 'Hello', 'start': 0, 'end': .2}, *partial['words']]}, text, mapping, 0, 0, 1, require_complete=True)


def test_alignment_admission_is_fifo_with_newer_generation_requests(recording, monkeypatch):
    app, client, _, _, request, original = recording
    first = client.post('/v1/jobs', json={**request, 'request_id': 'older-render'}).json()
    later = client.post('/v1/jobs', json={**request, 'request_id': 'newer-render'}).json()
    worker = app.state.worker
    worker.update(first['id'], lambda j: j.update(created_at='2020-01-01T00:00:00+00:00'))
    worker.update(original['id'], lambda j: j.update(alignment_status='queued', alignment_requested_at='2021-01-01T00:00:00+00:00'))
    worker.update(later['id'], lambda j: j.update(created_at='2022-01-01T00:00:00+00:00'))
    order = []
    def rendered(identity):
        order.append(('render', identity))
        worker.update(identity, lambda j: j.update(status='completed'))
        if len(order) == 3: worker.stop.set()
    def aligned(identity):
        order.append(('alignment', identity))
        worker.update(identity, lambda j: j.update(alignment_status='completed'))
    monkeypatch.setattr(worker, 'run', rendered)
    monkeypatch.setattr(worker, 'run_alignment', aligned)
    worker.loop()
    assert order == [('render', first['id']), ('alignment', original['id']), ('render', later['id'])]
