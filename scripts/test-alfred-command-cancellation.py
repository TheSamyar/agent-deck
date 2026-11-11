#!/usr/bin/env python3
"""Exercise real approved-command process-group cancellation in a temporary folder."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

RUNNER = Path(__file__).resolve().parents[1] / "native/Resources/Jarvis/project-command.py"


class ApprovedCommandCancellationTests(unittest.TestCase):
    def test_cancel_stops_child_before_it_can_complete_side_effect(self):
        with tempfile.TemporaryDirectory(prefix="alfred-cancel-qa-") as folder:
            root = Path(folder)
            ready, completed = root / "ready", root / "completed"
            child = "from pathlib import Path; import time; Path('ready').write_text('ready'); time.sleep(1); Path('completed').write_text('unexpected')"
            process = subprocess.Popen([sys.executable, str(RUNNER), json.dumps([sys.executable, "-c", child])], cwd=root,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    self.assertIsNone(process.poll(), "Runner exited before starting the child")
                    time.sleep(0.01)
                self.assertTrue(ready.exists(), "Child did not start within five seconds")
                process.terminate()
                process.wait(timeout=3)
                time.sleep(1.1)
                self.assertFalse(completed.exists(), "Cancellation left the child command running")
                self.assertNotEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
