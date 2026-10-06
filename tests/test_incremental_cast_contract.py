"""Original public book, synthetic analyzer transport; no model or private data."""
import json
import time
import uuid
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from bookpocket_companion.app import create_app
from bookpocket_companion.casting import Character, reconcile_characters
from bookpocket_companion.models import Config
from bookpocket_companion.store import canonical


def wait_analysis(client, identity):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        job = client.get('/v1/analyses/' + identity).json()
        if job['status'] not in {'queued', 'running'}:
            return job
        time.sleep(.02)
    pytest.fail('Synthetic chapter analysis did not finish')


def test_chapter_analysis_reuses_aliases_preserves_other_chapter_and_cache(tmp_path, monkeypatch):
    calls = []
    original_post = httpx.Client.post

    def response(client, url, **kwargs):
        if not str(url).endswith('/chat/completions'):
            return original_post(client, url, **kwargs)
        prompt = json.loads(kwargs['json']['messages'][1]['content'])
        calls.append(prompt)
        # Deliberately propose a new ID in the second chapter. Stable name/alias
        # reconciliation must retain the saved character and its voice choice.
        identity = 'mira' if len(calls) == 1 else 'new-mira-id'
        answer = {'characters': [{'id': identity, 'name': 'Mira', 'aliases': ['Lantern keeper']}],
                  'assignments': [{'utterance_id': u['utterance_id'], 'source_text': u['source_text'],
                                   'character_id': identity, 'confidence': .8} for u in prompt['utterances']]}
        return httpx.Response(200, request=httpx.Request('POST', url), json={'choices': [
            {'finish_reason': 'stop', 'message': {'content': json.dumps(answer)}}]})

    monkeypatch.setattr(httpx.Client, 'post', response)
    app = create_app(Config(data_dir=tmp_path, admin_token='synthetic-chapter-admin', dev=True), engines={}, start_worker=False)
    with TestClient(app, client=('127.0.0.1', 1234), headers={'Authorization': 'Bearer synthetic-chapter-admin'}) as client:
        with (Path(__file__).parent / 'fixtures/lantern.epub').open('rb') as source:
            result = client.post('/v1/books', files={'file': ('lantern.epub', source, 'application/epub+zip')})
        assert result.status_code == 200, result.text
        book = result.json()
        chapters = [c for c in book['chapters'] if any('“' in s['text'] for s in c['segments'])]
        assert len(chapters) >= 2
        route = '/v1/books/' + book['id']
        assert client.put('/v1/admin/analyzer', json={'url': 'http://127.0.0.1:1/v1', 'model': 'synthetic-chapter-transport'}).status_code == 200
        first_request = {'request_id': str(uuid.uuid4()), 'chapter_ids': [chapters[0]['id']]}
        first = client.post(route + '/analyze', json=first_request)
        assert first.status_code == 202, first.text
        assert wait_analysis(client, first.json()['id'])['status'] == 'completed'
        saved = client.get(route + '/cast').json()
        speaker = next(c for c in saved['characters'] if c['id'] == 'mira')
        speaker['voice_id'] = 'private-choice-preserved-test-only'
        saved['assignments'][0]['reviewed'] = True
        assert client.put(route + '/cast', json=saved).status_code == 200
        before = saved['assignments']
        second_request = {'request_id': str(uuid.uuid4()), 'chapter_ids': [chapters[1]['id']]}
        second = client.post(route + '/analyze', json=second_request)
        assert second.status_code == 202, second.text
        assert wait_analysis(client, second.json()['id'])['status'] == 'completed'
        merged = client.get(route + '/cast').json()
        assert all(row in merged['assignments'] for row in before), 'Earlier unreviewed suggestions and reviewed correction both survive'
        assert not any(c['id'] == 'new-mira-id' for c in merged['characters'])
        assert next(c for c in merged['characters'] if c['id'] == 'mira')['voice_id'] == speaker['voice_id']
        assert {row['character_id'] for row in merged['assignments']} == {'mira'}
        assert client.get(route).json()['chapters'] == book['chapters']
        count = len(calls)
        cached = client.post(route + '/analyze', json={**second_request, 'request_id': str(uuid.uuid4())})
        assert cached.status_code == 202, cached.text
        assert cached.json()['status'] == 'completed'
        assert cached.json()['reused_chapter_ids'] == [chapters[1]['id']]
        assert len(calls) == count
        assert client.post(route + '/analyze', json=first_request).json()['id'] == first.json()['id']
        statuses = client.get(route + '/analysis-status').json()['chapters']
        assert all(next(v for v in statuses if v['chapter_id'] == c['id'])['status'] == 'completed' for c in chapters[:2])


def test_alias_collision_requires_review_instead_of_merging_distinct_speakers():
    known = {'mira': Character(id='mira', name='Mira', aliases=['Guide'], voice_id='mira-voice'),
             'rowan': Character(id='rowan', name='Rowan', aliases=['Guide'], voice_id='rowan-voice')}
    with pytest.raises(ValueError, match='multiple saved speakers'):
        reconcile_characters(known, [{'id': 'new-guide', 'name': 'Guide'}])
    assert known['mira'].voice_id == 'mira-voice' and known['rowan'].voice_id == 'rowan-voice'


def test_restart_recovers_pending_chapter_status_as_failed_without_model(tmp_path):
    config = Config(data_dir=tmp_path, admin_token='synthetic-restart-admin', dev=True)
    app = create_app(config, engines={}, start_worker=False)
    with TestClient(app, client=('127.0.0.1', 1234), headers={'Authorization': 'Bearer synthetic-restart-admin'}) as client:
        book = client.post('/v1/books', files={'file': ('original.txt', 'The lantern glowed.')}).json()
    # Crash-boundary durable state: the worker never gets an opportunity to
    # finish its chapter. Reconstruct the real API and startup recovery path.
    pending = {'id': 'interrupted-chapter-test', 'book_id': book['id'], 'status': 'running',
               'chapter_statuses': [{'chapter_id': book['chapters'][0]['id'], 'status': 'running'}]}
    with app.state.store.db() as db:
        db.execute('INSERT INTO analyses VALUES(?,?)', (pending['id'], canonical(pending)))
    restored = create_app(config, engines={}, start_worker=False)
    with TestClient(restored, client=('127.0.0.1', 1234), headers={'Authorization': 'Bearer synthetic-restart-admin'}) as client:
        job = client.get('/v1/analyses/' + pending['id']).json()
        assert job['status'] == 'failed'
        assert job['chapter_statuses'][0]['status'] == 'failed'
        assert 'restart' in job['chapter_statuses'][0]['error']
