"""Explicit fake CLI fixtures test transport boundaries, never model quality."""
import json
import base64
import os
from pathlib import Path
import sys
import threading
import time
import uuid
import pytest
from fastapi.testclient import TestClient
from bookpocket_companion import antigravity_analyzer as agy
from bookpocket_companion.app import create_app
from bookpocket_companion.casting import ANALYSIS_SCHEMA
from bookpocket_companion.models import Config
from bookpocket_companion.scheduler import WorkCancelled

RESULT = {'characters': [{'id': 'mira', 'name': 'Mira', 'aliases': []}], 'assignments': [
    {'utterance_id': 'u00000', 'source_text': '“Keep walking.”', 'character_id': 'mira', 'confidence': .9}]}
SCRIPT = '''import json,sys,time,pathlib,re,base64
mode=sys.argv[1]
assert 'PRIVATE_SOURCE_SENTINEL' not in str(sys.argv)
tools=None if mode=='badtools' else ['view_file','run_command']
print(json.dumps({'event':'init','init':{'tools':tools,'model':'wrong' if mode=='badmodel' else 'gemini-3.1-pro-high','agent':'bookpocket-casting'}}),flush=True)
if mode=='hang':
 time.sleep(60)
data=json.loads(sys.stdin.readline())
assert 'PRIVATE_SOURCE_SENTINEL' not in data['message']['content']
hooks=json.loads(pathlib.Path('.agents/hooks.json').read_text())
command=hooks['bookpocket-tools-denied']['PreInvocation'][0]['command']
script=base64.b64decode(command.split()[-1]).decode('utf-16le')
nonce=re.search(r'"guard":"([0-9a-f]+)"',script)[1]
if mode!='nohook':pathlib.Path('.agents/bookpocket-hook-ready.json').write_text(json.dumps({'guard':nonce}))
print(json.dumps({'event':'result','result':{'status':'SUCCESS','structured_output':{'characters':[],'assignments':[]}}}),flush=True)
if mode=='no-read':time.sleep(60)
data=json.loads(sys.stdin.readline())
assert data['event']=='user' and 'PRIVATE_SOURCE_SENTINEL' in data['message']['content']
if mode=='tool':print(json.dumps({'event':'step_update','step_update':{'step_type':'tool','tool_name':'run_command'}}),flush=True)
if mode=='unknown':print(json.dumps({'event':'unexpected'}),flush=True)
if mode=='flood':print('x'*1100000,flush=True)
result=json.loads(sys.argv[2])
if mode=='invalid':result['assignments'][0]['confidence']='PRIVATE_SOURCE_SENTINEL'
if mode!='missing':print(json.dumps({'event':'result','result':{'status':'ERROR' if mode=='error' else 'SUCCESS','structured_output':result}}),flush=True)
sys.exit(1 if mode=='nonzero' else 0)
'''


@pytest.fixture
def fixture_cli(tmp_path, monkeypatch):
    helper = tmp_path / 'explicit_fake_agy.py'
    helper.write_text(SCRIPT)
    monkeypatch.setattr(agy, 'policy_check', lambda: None)
    monkeypatch.setattr(agy, 'cli_path', lambda path=None: Path(sys.executable))
    monkeypatch.setattr(agy, '_powershell_path', lambda: Path(sys.executable))
    native = agy._spawn
    state = {'mode': 'happy'}
    def spawn(command, *args):
        state['command'] = command
        state['cwd'] = args[-1]
        return native([sys.executable, str(helper), state['mode'], json.dumps(RESULT), *command[1:]], *args)
    monkeypatch.setattr(agy, '_spawn', spawn)
    return state


def call_fixture(state, **kwargs):
    return agy.classify({'model': agy.MODEL}, 'Return exact classifications.',
                        {'source': 'PRIVATE_SOURCE_SENTINEL'}, ANALYSIS_SCHEMA, **kwargs)


def test_source_uses_pipes_and_pinned_safe_flags_with_successful_terminal_schema(fixture_cli):
    assert call_fixture(fixture_cli) == RESULT
    command = fixture_cli['command']
    assert agy.MODEL in command and agy.AGENT in command
    assert '--dangerously-skip-permissions' not in command
    assert '--disable-slash-commands' in command and '--mode' in command
    assert 'PRIVATE_SOURCE_SENTINEL' not in str(command)
    assert not fixture_cli['cwd'].exists()


@pytest.mark.parametrize('mode', ['badtools','badmodel','nohook','tool','unknown','flood','invalid','missing','error','nonzero'])
def test_failed_or_unsafe_cli_output_never_claims_success_or_leaks_source(fixture_cli, mode):
    fixture_cli['mode'] = mode
    with pytest.raises(ValueError) as error: call_fixture(fixture_cli, timeout=3)
    assert 'PRIVATE_SOURCE_SENTINEL' not in str(error.value)
    assert not fixture_cli['cwd'].exists()


def test_timeout_and_cancel_stop_exact_owned_cli_tree(fixture_cli):
    fixture_cli['mode'] = 'hang'
    started = time.monotonic()
    with pytest.raises(ValueError, match='timed out'): call_fixture(fixture_cli, timeout=.3)
    assert time.monotonic()-started < 5
    event = threading.Event()
    timer = threading.Timer(.2, event.set); timer.start()
    try:
        with pytest.raises(WorkCancelled): call_fixture(fixture_cli, cancel_event=event)
    finally: timer.cancel()


def test_blocked_large_stdin_writer_cannot_block_cancellation(fixture_cli):
    fixture_cli['mode'] = 'no-read'
    started = time.monotonic()
    with pytest.raises(ValueError, match='timed out'):
        agy.classify({'model': agy.MODEL}, 'Classify.', {'source':'PRIVATE_SOURCE_SENTINEL'+'x'*500000}, ANALYSIS_SCHEMA, timeout=.3)
    assert time.monotonic()-started < 5


@pytest.mark.parametrize('value', [True, 'true', 1, None, [], {}])
def test_paid_credits_unknown_policy_fail_closed(tmp_path, value):
    settings = tmp_path / '.gemini/antigravity-cli/settings.json'
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({'useG1Credits': value}))
    with pytest.raises(ValueError, match='credit'): agy.policy_check(tmp_path)
    settings.write_text(json.dumps({'useG1Credits': False}))
    agy.policy_check(tmp_path)


@pytest.mark.parametrize('name,value', [('hooks.json', {'capture':{'PreInvocation':[{'command':'unsafe'}]}}),
                                       ('hooks.json', {'unknown':'unsafe'}), ('hooks.json', []),
                                       ('plugins.json', {'entries':[{'path':'unsafe'}]}),
                                       ('settings.json', {'hooks':{'capture':True}})])
def test_executable_or_unrecognized_global_customizations_fail_closed(tmp_path, name, value):
    path = tmp_path / '.gemini/config' / name
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError): agy.policy_check(tmp_path)


def test_hook_commands_handle_workspace_spaces_and_apostrophes_without_source_in_argv(tmp_path, monkeypatch):
    monkeypatch.setattr(agy, '_powershell_path', lambda: Path(sys.executable))
    root = tmp_path / "Reader's private workspace"
    hooks = agy._hook_manifest(root, 'fixed-public-nonce')['bookpocket-tools-denied']
    bootstrap = hooks['PreInvocation'][0]['command']
    script = base64.b64decode(bootstrap.split()[-1]).decode('utf-16le')
    assert "Reader''s private workspace" in script
    assert 'fixed-public-nonce' in script and 'PRIVATE_SOURCE_SENTINEL' not in bootstrap
    assert '[Console]::In.ReadToEnd()' in script
    denial = hooks['PreToolUse'][0]
    assert denial['matcher'] == '*'
    deny_script = base64.b64decode(denial['hooks'][0]['command'].split()[-1]).decode('utf-16le')
    assert '"decision":"deny"' in deny_script and 'allow' not in deny_script
    assert '[Console]::In.ReadToEnd()' in deny_script


@pytest.mark.parametrize('response', [json.dumps(RESULT), '```json\n'+json.dumps(RESULT)+'\n```'])
def test_cli_response_compatibility_accepts_only_one_whole_schema_valid_object(response):
    assert agy._terminal_output({'response':response}, ANALYSIS_SCHEMA) == RESULT


@pytest.mark.parametrize('response', [json.dumps(RESULT)+'\n'+json.dumps(RESULT),
    '```json\n'+json.dumps(RESULT)+'\n```\n```json\n'+json.dumps(RESULT)+'\n```',
    'Some prose '+json.dumps(RESULT), '{"characters":[],"characters":[],"assignments":[]}',
    '{"characters":[],"assignments":[],"extra":true}'])
def test_repeated_markdown_extra_prose_and_duplicate_keys_cannot_claim_success(response):
    with pytest.raises(ValueError): agy._terminal_output({'response':response}, ANALYSIS_SCHEMA)


def test_global_mcp_servers_cannot_start_as_cli_side_effects(tmp_path):
    path = tmp_path / '.gemini/config/mcp_config.json'
    path.parent.mkdir(parents=True)
    for text in ('', '  ', '{}', '{"mcpServers":{}}'):
        path.write_text(text)
        agy.policy_check(tmp_path)
    for text in ('[]', 'invalid', '{"mcpServers":{"private":{"command":"unsafe"}}}'):
        path.write_text(text)
        with pytest.raises(ValueError, match='MCP'): agy.policy_check(tmp_path)


def test_api_key_model_provider_cannot_replace_subscription_route(tmp_path):
    path = tmp_path / '.gemini/antigravity-cli/settings.json'
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({'modelProvider':'gemini'}))
    with pytest.raises(ValueError, match='subscription'): agy.policy_check(tmp_path)


def test_provider_preserves_consent_exact_source_and_cache_without_http_fallback(tmp_path, monkeypatch):
    calls = []
    def classify(settings, instruction, prompt, schema, **kwargs):
        calls.append(prompt)
        return {'characters': RESULT['characters'], 'assignments': [
            {**u, 'character_id':'mira', 'confidence':.9} for u in prompt['utterances']]}
    monkeypatch.setattr(agy, 'classify', classify)
    monkeypatch.setattr(agy, 'readiness', lambda configured=None: {'ready':True,'authentication_checked':False})
    config = Config(data_dir=tmp_path, dev=True)
    app = create_app(config, engines={}, start_worker=False)
    with TestClient(app, client=('127.0.0.1',1), headers={'Authorization':'Bearer '+config.admin_token}) as client:
        settings = {'provider':'antigravity','url':'','cli_path':None,'model':agy.MODEL,'api_key':''}
        saved = client.put('/v1/admin/analyzer',json=settings)
        assert saved.status_code == 200, saved.text
        assert saved.json()['hosted'] and not saved.json()['has_api_key'] and saved.json()['url'] is None
        source = 'Mira said, “Keep walking.”'
        book = client.post('/v1/books',files={'file':('public.txt',source.encode())}).json()
        route='/v1/books/'+book['id']
        request={'request_id':str(uuid.uuid4()),'chapter_ids':[book['chapters'][0]['id']]}
        assert client.post(route+'/analyze',json=request).status_code == 409 and not calls
        response = client.post(route+'/analyze',json={**request,'allow_hosted':True})
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            job=client.get('/v1/analyses/'+response.json()['id']).json()
            if job['status'] not in {'queued','running'}:break
            time.sleep(.02)
        assert job['status']=='completed',job.get('error')
        assert len(calls)==1 and client.get(route+'/source').content==source.encode()
        cached=client.post(route+'/analyze',json={**request,'request_id':str(uuid.uuid4()),'allow_hosted':True}).json()
        assert cached['status']=='completed' and cached['reused_chapter_ids']==request['chapter_ids'] and len(calls)==1
        assert client.put('/v1/admin/analyzer',json={**settings,'api_key':'private-key'}).status_code==400
        assert client.put('/v1/admin/analyzer',json={**settings,'model':'auto'}).status_code==400
        assert client.put('/v1/admin/analyzer',json={**settings,'cli_path':'relative.exe'}).status_code==400
