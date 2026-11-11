#!/usr/bin/env python3
"""Wake worker invalid-asset checks. No mic, model inference, downloads or account access."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WORKER = Path(__file__).resolve().parents[1] / "native/Resources/AlfredWake/worker.py"


class WakeWorkerValidationQA(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="alfred-wake-worker-qa-")
        self.root = Path(self.temp.name)
        self.manifest = self.root / "model-manifest.json"

    def tearDown(self):
        self.temp.cleanup()

    def reject(self, manifest):
        self.manifest.write_text(json.dumps(manifest))
        result = subprocess.run([sys.executable, str(WORKER), "--manifest", str(self.manifest), "--check"],
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        self.assertTrue(any(event.get("type") == "error" for event in events))
        self.assertFalse(any(event.get("type") == "ready" for event in events))

    def test_wrong_wake_phrase_cannot_be_reported_ready(self):
        self.reject({"version": 1, "verification_phrase": "Hey Jarvis", "files": []})

    def test_path_traversal_is_rejected_before_read(self):
        self.reject({"version": 1, "verification_phrase": "Hey Alfred", "files": [
            {"name": "../outside.onnx", "sha256": "0" * 64}]})

    def test_modified_model_cannot_be_reported_ready(self):
        (self.root / "alfred.onnx").write_bytes(b"changed")
        self.reject({"version": 1, "verification_phrase": "Hey Alfred", "files": [
            {"name": "alfred.onnx", "sha256": hashlib.sha256(b"original").hexdigest()}]})

    def test_missing_model_cannot_be_reported_ready(self):
        self.reject({"version": 1, "verification_phrase": "Hey Alfred", "files": [
            {"name": "alfred.onnx", "sha256": "0" * 64}]})


if __name__ == "__main__":
    unittest.main()
