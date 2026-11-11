#!/usr/bin/env python3
"""Installer transaction tests: no downloads, dependency install, microphone or live settings."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1]/'native/Resources/AlfredWake/setup.py'
spec = importlib.util.spec_from_file_location('alfred_wake_setup', MODULE)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class WakeInstallTransactionTests(unittest.TestCase):
    def run_install(self, *, bad_hash=False, bad_worker=False, activation_error=False):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder)
            source = parent/'source'; source.mkdir()
            root = parent/'AlfredWake'; root.mkdir()
            (root/'previous-marker').write_text('preserved')
            payload = b'candidate-model'
            manifest = {'version': 1, 'verification_phrase': 'Hey Alfred', 'validated_acoustically': False,
                        'files': [{'name': 'alfred.onnx', 'url': 'https://example.test/alfred.onnx',
                                   'sha256': '0'*64 if bad_hash else hashlib.sha256(payload).hexdigest()}]}
            (source/'model-manifest.json').write_text(json.dumps(manifest))
            (source/'requirements.txt').write_text('fixture==1\n')
            (source/'worker.py').write_text('# fixture\n')
            def run(arguments, **_):
                if arguments[1] == 'venv':
                    environment = Path(arguments[-1]); (environment/'bin').mkdir(parents=True)
                    (environment/'bin/python').write_text('fixture')
                if '--check' in arguments and bad_worker:
                    raise subprocess.CalledProcessError(1, arguments)
                return subprocess.CompletedProcess(arguments, 0)
            original_rename = Path.rename
            def rename(path, target):
                if activation_error and path.name == 'runtime':
                    raise OSError('Injected activation failure')
                return original_rename(path, target)
            with patch.object(Path, 'rename', rename), patch.object(installer, 'uv_binary', return_value='/fixture/uv'), \
                 patch.object(installer.subprocess, 'run', side_effect=run), \
                 patch.object(installer.urllib.request, 'urlopen', side_effect=lambda *_a, **_k: io.BytesIO(payload)), \
                 patch.object(installer, 'emit'):
                if bad_hash or bad_worker or activation_error:
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError, OSError)):
                        installer.install(root, source)
                    self.assertEqual((root/'previous-marker').read_text(), 'preserved')
                    self.assertFalse((root/'ready.json').exists())
                else:
                    installer.install(root, source)
                    self.assertEqual((root/'alfred.onnx').read_bytes(), payload)
                    self.assertFalse(json.loads((root/'ready.json').read_text())['validatedAcoustically'])
                    archived = list((parent/'AlfredWakePrevious').glob('*/previous-marker'))
                    self.assertEqual(len(archived), 1)
                    self.assertEqual(archived[0].read_text(), 'preserved')
                self.assertFalse(list(parent.glob('.alfred-wake-staging-*')))

    def test_checksum_failure_preserves_existing_runtime(self): self.run_install(bad_hash=True)
    def test_worker_failure_preserves_existing_runtime(self): self.run_install(bad_worker=True)
    def test_success_archives_previous_and_preserves_unvalidated_state(self): self.run_install()
    def test_activation_failure_restores_previous_runtime(self): self.run_install(activation_error=True)


if __name__ == '__main__': unittest.main()
