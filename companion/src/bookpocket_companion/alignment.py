"""Managed English word alignment, independent of VoiceStudio and audio bytes."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from .engines import python_in
from .setup_process import run_setup
from .scheduler import WorkOwnershipUncertain

MODEL_REPO = 'facebook/wav2vec2-base-960h'
MODEL_REVISION = '22aad52d435eb6dbaf354bdad9b0da84ce7d6156'
MODEL_FILES = ('config.json', 'model.safetensors', 'preprocessor_config.json',
               'special_tokens_map.json', 'tokenizer_config.json', 'vocab.json')
# Content identities from the pinned upstream Git tree. Small files use Git
# blob SHA1; the safe weight file uses its upstream LFS SHA256.
MODEL_HASHES = {
    'config.json': ('git', '8ca9cc7496e145e37d09cec17d0c3bf9b8523c8e'),
    'model.safetensors': ('sha256', '8aa76ab2243c81747a1f832954586bc566090c83a0ac167df6f31f0fa917d74a'),
    'preprocessor_config.json': ('git', '3f24dc078fcba55ee1d417a413847ead40c093a3'),
    'special_tokens_map.json': ('git', '25bc39604f72700b3b8e10bd69bb2f227157edd1'),
    'tokenizer_config.json': ('git', '978a15a96dbb2d23e2afbc70137cae6c5ce38c8d'),
    'vocab.json': ('git', '88181b954aa14df68be9b444b3c36585f3078c0a'),
}


class WordAligner:
    def __init__(self, config):
        self.config = config
        self.root = config.data_dir / 'engines' / 'word-alignment'
        self.model = self.root / 'models' / MODEL_REVISION
        self.process = self.log = None
        self.verified_fingerprint = None

    @property
    def python(self):
        managed = python_in(self.config.data_dir / 'engines' / 'omnivoice' / 'venv')
        return managed if managed.is_file() else python_in(self.root / 'venv')

    def ready(self):
        try:
            marker = json.loads((self.root / 'ready.json').read_text(encoding='utf-8'))
            available = (marker.get('revision') == MODEL_REVISION and marker.get('validated_model') is True
                         and marker.get('file_hashes') == {name: value[1] for name, value in MODEL_HASHES.items()}
                         and self.python.is_file() and all((self.model / name).is_file() for name in MODEL_FILES))
            if available: self.verify_model()
            return available
        except (OSError, ValueError): return False

    def verify_model(self):
        fingerprint = tuple((name, (self.model / name).stat().st_size, (self.model / name).stat().st_mtime_ns) for name in MODEL_FILES)
        if self.verified_fingerprint == fingerprint: return
        for name, (kind, expected) in MODEL_HASHES.items():
            path = self.model / name
            hasher = hashlib.sha256() if kind == 'sha256' else hashlib.sha1()
            if kind == 'git': hasher.update(f'blob {path.stat().st_size}\0'.encode())
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''): hasher.update(chunk)
            if hasher.hexdigest() != expected: raise ValueError(f'The word alignment model file {name} failed its pinned integrity check; reinstall alignment')
        self.verified_fingerprint = fingerprint

    def environment(self):
        env = dict(os.environ)
        env.update(PYTHONUTF8='1', HF_HUB_DISABLE_TELEMETRY='1', HF_HOME=str(self.root / 'cache'))
        return env

    def install(self, cancel_event=None):
        self.root.mkdir(parents=True, exist_ok=True)
        with (self.root / 'install.log').open('a', encoding='utf-8') as log:
            def run(command, **kwargs):
                return run_setup(command, cancel_event=cancel_event, stdout=log, stderr=log,
                                 check=True, env=self.environment(), **kwargs)
            if not self.python.is_file():
                run([sys.executable, '-m', 'venv', str(self.root / 'venv')])
                run([str(self.python), '-m', 'pip', 'install', 'torch==2.11.0', '--index-url', 'https://download.pytorch.org/whl/cpu'])
                run([str(self.python), '-m', 'pip', 'install', 'transformers==5.10.0', 'soundfile==0.13.1'])
            # Existing OmniVoice's interpreter already has these dependencies;
            # model files are separate and its setup marker is never modified.
            hf = self.python.with_name('hf.exe' if os.name == 'nt' else 'hf')
            run([str(hf), 'download', MODEL_REPO, *MODEL_FILES, '--revision', MODEL_REVISION,
                 '--local-dir', str(self.model)])
            self.verify_model()
            run([str(self.python), str(Path(__file__).with_name('alignment_worker.py'))],
                input=json.dumps({'model': str(self.model), 'probe': True}) + '\n', text=True, timeout=300)
        if not all((self.model / name).is_file() for name in MODEL_FILES): raise ValueError('The English word alignment model is incomplete')
        temporary = self.root / 'ready.tmp'
        temporary.write_text(json.dumps({'revision': MODEL_REVISION, 'model': MODEL_REPO,
                                         'license': 'Apache-2.0', 'validated_model': True,
                                         'file_hashes': {name: value[1] for name, value in MODEL_HASHES.items()}}), encoding='utf-8')
        if cancel_event is not None and cancel_event.is_set(): raise RuntimeError('Alignment setup stopped')
        temporary.replace(self.root / 'ready.json')

    def align(self, audio, text, language='en', start=0, end=None):
        if not self.ready(): raise RuntimeError('Install English word alignment before preparing this recording')
        with tempfile.TemporaryDirectory(prefix='word-alignment-', dir=self.root) as temporary:
            normalized = Path(temporary) / 'speech.wav'
            command = [self.config.ffmpeg, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(audio)]
            if start: command += ['-ss', str(start)]
            if end is not None: command += ['-t', str(end - start)]
            subprocess.run([*command, '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(normalized)],
                           check=True, capture_output=True, timeout=120)
            return self.request({'model': str(self.model), 'audio': str(normalized), 'text': text, 'language': language})

    def request(self, payload):
        if self.process is None or self.process.poll() is not None:
            self.close()
            self.log = (self.root / 'alignment.log').open('a', encoding='utf-8')
            env = self.environment()
            env.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1')
            self.process = subprocess.Popen([str(self.python), '-u', str(Path(__file__).with_name('alignment_worker.py'))],
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                            text=True, encoding='utf-8', env=env)
        self.process.stdin.write(json.dumps(payload) + '\n')
        self.process.stdin.flush()
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        future = executor.submit(self.process.stdout.readline)
        try:
            line = future.result(timeout=300)
            if not line: raise RuntimeError('Word alignment process stopped; check the local alignment log')
            result = json.loads(line)
            if not result.get('ok'): raise ValueError(result.get('error', 'Word alignment failed'))
            return result
        except BaseException:
            self.close()
            raise
        finally: executor.shutdown(wait=False, cancel_futures=True)

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                try: self.process.wait(timeout=5)
                except subprocess.TimeoutExpired as exc: raise WorkOwnershipUncertain('Word alignment process did not stop') from exc
        self.process = None
        if self.log is not None: self.log.close()
        self.log = None
