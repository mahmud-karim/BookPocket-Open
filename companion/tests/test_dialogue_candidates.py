"""Prevent the reserved prose narrator becoming a dialogue candidate whitelist."""
import json
import time
import uuid

import httpx
from fastapi.testclient import TestClient

from bookpocket_companion.app import create_app
from bookpocket_companion.models import Config


def test_dialogue_candidates_allow_new_speaker_and_keep_narrator_guard(tmp_path, monkeypatch):
    captured = []
    original = httpx.Client.post

    def respond(client, url, **kwargs):
        if not str(url).endswith('/chat/completions'):
            return original(client, url, **kwargs)
        prompt = json.loads(kwargs['json']['messages'][1]['content'])
        captured.append(prompt)
        assert all(c['id'] != 'narrator' for c in prompt['characters'])
        assert any(c['id'] == 'rowan' for c in prompt['characters'])
        assert all('voice_id' not in c for c in prompt['characters'])
        speaker = 'mira' if len(captured) == 1 else 'narrator'
        result = {'characters': [{'id': speaker, 'name': 'Mira' if speaker == 'mira' else 'Narrator', 'aliases': []}],
                  'assignments': [{'utterance_id': u['utterance_id'], 'source_text': u['source_text'],
                                   'character_id': speaker, 'confidence': .8} for u in prompt['utterances']]}
        return httpx.Response(200, request=httpx.Request('POST', url), json={'choices': [
            {'finish_reason': 'stop', 'message': {'content': json.dumps(result)}}]})

    monkeypatch.setattr(httpx.Client, 'post', respond)
    config = Config(data_dir=tmp_path, admin_token='dialogue-candidate-test', dev=True)
    app = create_app(config, engines={}, start_worker=False)
    with TestClient(app, client=('127.0.0.1', 1), headers={'Authorization': 'Bearer '+config.admin_token}) as client:
        book = client.post('/v1/books', files={'file': ('public.txt', 'Mira raised the lantern. “Hello,” she said.')}).json()
        route = '/v1/books/' + book['id']
        assert client.put(route+'/cast', json={'characters': [
            {'id': 'narrator', 'name': 'Narrator', 'voice_id': 'private-narrator-voice'},
            {'id': 'rowan', 'name': 'Rowan', 'voice_id': 'private-rowan-voice'}], 'assignments': []}).status_code == 200
        assert client.put('/v1/admin/analyzer', json={'url':'http://127.0.0.1:1/v1','model':'test-only'}).status_code == 200
        jobs = []
        for _ in range(2):
            response = client.post(route+'/analyze', json={'request_id':str(uuid.uuid4())})
            deadline = time.monotonic()+10
            while time.monotonic()<deadline:
                job = client.get('/v1/analyses/'+response.json()['id']).json()
                if job['status'] not in {'queued', 'running'}: break
                time.sleep(.02)
            jobs.append(job)
        assert jobs[0]['status'] == 'completed'
        assert jobs[1]['status'] == 'failed' and 'not narrator' in jobs[1]['error']
        saved = client.get(route+'/cast').json()
        assert saved['assignments'][0]['character_id'] == 'mira'
        assert next(c for c in saved['characters'] if c['id']=='narrator')['voice_id']=='private-narrator-voice'
        assert client.get(route).json()['chapters'] == book['chapters']
