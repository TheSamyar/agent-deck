#!/usr/bin/env python3
"""Explicit optional install. Stage and check all assets before replacing a working runtime."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request


def emit(kind, message):
    print(json.dumps({'type': kind, 'message': message}), flush=True)


def uv_binary():
    candidates = [shutil.which('uv'), str(pathlib.Path.home()/'.local/bin/uv'), '/opt/homebrew/bin/uv', '/usr/local/bin/uv']
    return next((value for value in candidates if value and os.access(value, os.X_OK)), None)


def install(root, source):
    uv = uv_binary()
    if not uv:
        raise RuntimeError('Install uv from astral.sh/uv, then retry Install wake runtime. Manual Listen still works.')
    manifest = json.loads((source/'model-manifest.json').read_text())
    if manifest.get('version') != 1 or manifest.get('verification_phrase') != 'Hey Alfred':
        raise RuntimeError('Invalid Alfred wake manifest.')
    root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root.parent/'.alfred-wake-install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix='.alfred-wake-staging-', dir=str(root.parent)) as temporary:
            stage = pathlib.Path(temporary)/'runtime'
            stage.mkdir(mode=0o700)
            emit('status', 'Preparing isolated Python 3.11 wake runtime…')
            subprocess.run([uv, 'venv', '--python', '3.11', str(stage/'venv')], check=True, stdout=sys.stderr)
            python = stage/'venv/bin/python'
            subprocess.run([uv, 'pip', 'sync', '--python', str(python), str(source/'requirements.txt')], check=True, stdout=sys.stderr)
            for item in manifest['files']:
                name = item['name']
                if pathlib.Path(name).name != name or not name.endswith('.onnx') or not item['url'].startswith('https://'):
                    raise RuntimeError('Invalid wake asset declaration.')
                emit('status', 'Downloading '+name+'…')
                digest = hashlib.sha256()
                with urllib.request.urlopen(item['url'], timeout=60) as response, (stage/name).open('wb') as target:
                    total = 0
                    while True:
                        chunk = response.read(1024*1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > 100*1024*1024:
                            raise RuntimeError('Wake model exceeds download size limit.')
                        digest.update(chunk)
                        target.write(chunk)
                if digest.hexdigest() != item['sha256']:
                    raise RuntimeError('Downloaded model checksum mismatch: '+name)
            (stage/'model-manifest.json').write_text(json.dumps(manifest, indent=2))
            emit('status', 'Checking the wake worker without opening the microphone…')
            subprocess.run([str(python), str(source/'worker.py'), '--manifest', str(stage/'model-manifest.json'), '--check'], check=True, timeout=60, stdout=sys.stderr)
            (stage/'ready.json').write_text(json.dumps({'version': 1, 'modelSHA256': manifest['files'][0]['sha256'], 'validatedAcoustically': manifest.get('validated_acoustically', False)}))
            backup = None
            if root.exists():
                backups = root.parent/'AlfredWakePrevious'
                backups.mkdir(mode=0o700, exist_ok=True)
                backup = backups/datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
                root.rename(backup)
            try:
                stage.rename(root)
            except BaseException:
                if backup is not None:
                    backup.rename(root)
                raise
    emit('installed', 'Experimental Alfred wake runtime installed. Acoustic accuracy is not certified; hands-free remains off until you enable it.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=pathlib.Path, default=pathlib.Path.home()/'Library/Application Support/Agent Deck/AlfredWake')
    args = parser.parse_args()
    try:
        install(args.directory.expanduser(), pathlib.Path(__file__).resolve().parent)
    except Exception as error:
        emit('error', str(error))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
