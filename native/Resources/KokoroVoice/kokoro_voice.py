"""Agent Deck's local Kokoro runtime. No network use during speech generation."""
import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
import wave

ASSETS = {
    'kokoro-v1.0.onnx': 'beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a',
    'voices-v1.0.bin': 'bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d',
}
VOICES = {'af_heart': 'en-us', 'af_bella': 'en-us', 'am_michael': 'en-us', 'bf_emma': 'en-gb'}
DEFAULT_ROOT = Path.home() / 'Library/Application Support/Agent Deck/Kokoro'
OUTPUT_LOCK = threading.Lock()


def emit(kind, **values):
    with OUTPUT_LOCK:
        print(json.dumps(dict(type=kind, **values)), flush=True)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for data in iter(lambda: source.read(1024 * 1024), b''):
            value.update(data)
    return value.hexdigest()


def install(root):
    uv = shutil.which('uv')
    if not uv:
        uv = next((str(p) for p in [Path.home()/'.local/bin/uv', Path('/opt/homebrew/bin/uv'), Path('/usr/local/bin/uv')] if p.is_file()), None)
    if not uv:
        raise RuntimeError('Install uv from astral.sh/uv, then click Install voice again.')
    root.mkdir(parents=True, exist_ok=True)
    python = root / 'venv/bin/python'
    emit('status', message='Preparing the isolated voice runtime…')
    if not python.exists():
        subprocess.run([uv, 'venv', '--python', '3.11', str(root/'venv')], stdout=sys.stderr, check=True)
    subprocess.run([uv, 'pip', 'sync', '--python', str(python), str(Path(__file__).with_name('requirements.txt'))], stdout=sys.stderr, check=True)
    for name, expected in ASSETS.items():
        target = root / name
        if target.exists() and digest(target) == expected:
            continue
        emit('status', message='Downloading '+name+'…')
        temporary = root / (name+'.download')
        url = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/'+name
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open('wb') as output:
            total = int(response.headers.get('Content-Length', '0'))
            received, last = 0, -1
            while True:
                chunk = response.read(1024*1024)
                if not chunk:
                    break
                output.write(chunk); received += len(chunk)
                percent = int(received*100/total) if total else -1
                if percent//10 != last:
                    last = percent//10
                    emit('status', message='Downloading '+name+(f' · {percent}%' if total else ''))
        if digest(temporary) != expected:
            raise RuntimeError('Voice model checksum failed. Retry Install voice; the existing model was preserved.')
        temporary.replace(target)
    (root/'ready.json').write_text(json.dumps({'engine':'kokoro-onnx', 'version':'0.6.1', 'assets':ASSETS}))
    emit('installed', message='Kokoro voice installed. Choose Preview voice to listen.')


def load(root):
    import onnxruntime as ort
    from kokoro_onnx import Kokoro
    ort.disable_telemetry_events()
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(root/'kokoro-v1.0.onnx'), sess_options=options, providers=['CPUExecutionProvider'])
    return Kokoro.from_session(session, str(root/'voices-v1.0.bin'))


def validate(request):
    if not isinstance(request, dict):
        raise ValueError('Expected a speech request object.')
    identifier = request.get('id')
    text = request.get('text')
    voice = request.get('voice', 'af_heart')
    speed = request.get('speed', 1.0)
    if not isinstance(identifier, str) or not identifier or len(identifier) > 100:
        raise ValueError('Invalid speech request id.')
    if not isinstance(text, str) or not text.strip() or len(text) > 16000:
        raise ValueError('Speech text must contain 1–16000 characters.')
    if voice not in VOICES or isinstance(speed, bool) or not isinstance(speed, (float,int)) or not 0.8 <= speed <= 1.2:
        raise ValueError('Invalid voice or speed.')
    return identifier, text, voice, speed


def segments(text):
    # Bundle tiny sentences for natural prosody; bound cancellation and latency.
    chunk = ''
    for word in text.split():
        if len(chunk)+len(word)+1 > 260 and chunk:
            yield chunk
            chunk = ''
        chunk += (' ' if chunk else '')+word
        if len(chunk) >= 120 and word.endswith(('.', '!', '?')):
            yield chunk
            chunk = ''
    if chunk:
        yield chunk


def serve(root):
    with contextlib.redirect_stdout(sys.stderr):
        model = load(root)
    emit('ready', engine='kokoro-onnx', voices=list(VOICES))
    requests = queue.Queue(maxsize=4)
    active = {}
    lock = threading.Lock()

    def read():
        for line in sys.stdin:
            identifier = None
            try:
                if len(line) > 100000:
                    raise ValueError('Speech request is too large.')
                item = json.loads(line)
                identifier = item.get('id') if isinstance(item, dict) else None
                if isinstance(item, dict) and item.get('type') == 'cancel':
                    with lock:
                        if identifier in active:
                            active[identifier].set()
                    continue
                identifier, text, voice, speed = validate(item)
                canceled = threading.Event()
                with lock:
                    for event in active.values():
                        event.set()
                    active[identifier] = canceled
                try:
                    requests.put_nowait((identifier,text,voice,speed,canceled))
                except queue.Full:
                    with lock:
                        active.pop(identifier, None)
                    raise ValueError('Voice is busy. Try again.')
            except Exception as error:
                emit('error', id=identifier, message=str(error))
        with lock:
            for event in active.values():
                event.set()
        requests.put(None)

    threading.Thread(target=read, daemon=True).start()
    while True:
        job = requests.get()
        if job is None:
            return
        identifier,text,voice,speed,canceled = job
        try:
            for part in segments(text):
                if canceled.is_set():
                    break
                with contextlib.redirect_stdout(sys.stderr):
                    audio, rate = model.create(part, voice=voice, speed=speed, lang=VOICES[voice])
                if canceled.is_set():
                    break
                import numpy as np
                pcm = (np.clip(audio, -1, 1)*32767).astype('<i2').tobytes()
                emit('audio', id=identifier, sampleRate=rate, pcm=base64.b64encode(pcm).decode('ascii'))
            if not canceled.is_set():
                emit('done', id=identifier)
        except Exception as error:
            emit('error', id=identifier, message=str(error))
        finally:
            with lock:
                active.pop(identifier, None)


def sample(root, destination, voice):
    start = time.monotonic()
    with contextlib.redirect_stdout(sys.stderr):
        model = load(root)
        audio, rate = model.create('Hello. I am your local supervisor. Tell me what you want your agents to work on, and we will take it one step at a time.', voice=voice, speed=1.0, lang=VOICES[voice])
    import numpy as np
    pcm = (np.clip(audio, -1, 1)*32767).astype('<i2').tobytes()
    with wave.open(str(destination),'wb') as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(rate); output.writeframes(pcm)
    emit('sample', seconds=len(audio)/rate, generationSeconds=round(time.monotonic()-start,2), bytes=len(pcm))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=DEFAULT_ROOT)
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--sample', type=Path)
    parser.add_argument('--voice', choices=list(VOICES), default='af_heart')
    args = parser.parse_args()
    try:
        if args.install:
            install(args.root)
        elif args.sample:
            sample(args.root,args.sample,args.voice)
        else:
            serve(args.root)
    except Exception as error:
        emit('error', message=str(error))
        sys.exit(1)
