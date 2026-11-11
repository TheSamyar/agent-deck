#!/usr/bin/env python3
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch
import urllib.error
import urllib.request

HELPER = Path(__file__).resolve().parents[1] / "native/Resources/Updates/private-update.py"
spec = importlib.util.spec_from_file_location("private_update", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class PrivateUpdateTests(unittest.TestCase):
    def test_candidates_keep_every_allowed_release_for_native_signed_build_selection(self):
        releases = [self.release("older-recreated"), self.release("newer-build"), self.release("preview", preview=True)]
        def stream(endpoint, limit, sink, *args, **kwargs):
            sink.write(json.dumps(releases).encode())
        with tempfile.TemporaryDirectory() as directory, patch.object(helper, "gh_stream", stream), patch.object(helper, "download") as download:
            result = helper.inspect("owner/repo", directory, False, candidates=True)
            self.assertEqual([item["tag"] for item in result["releases"]], ["older-recreated", "newer-build"])
            self.assertEqual([item["index"] for item in result["releases"]], [0, 1])
            self.assertEqual([call.args[2] for call in download.call_args_list], [Path(directory) / "0/appcast.xml", Path(directory) / "1/appcast.xml"])
            self.assertTrue(all(call.args[3] == helper.CANDIDATE_FEED_LIMIT for call in download.call_args_list))
            self.assertTrue(all(0 < call.kwargs["timeout"] <= 180 for call in download.call_args_list))

    def test_candidates_bound_count_feed_size_and_total_download_budget(self):
        def stream(endpoint, limit, sink, *args, **kwargs):
            sink.write(json.dumps([self.release(str(i)) for i in range(40)]).encode())
        with tempfile.TemporaryDirectory() as directory, patch.object(helper, "gh_stream", stream), patch.object(helper, "download") as download:
            self.assertEqual(len(helper.inspect("owner/repo", directory, True, candidates=True)["releases"]), 30)
            self.assertEqual(download.call_count, 30)
        oversized = self.release("too-large")
        oversized["assets"][0]["size"] = helper.CANDIDATE_FEED_LIMIT + 1
        def large_stream(endpoint, limit, sink, *args, **kwargs):
            sink.write(json.dumps([oversized]).encode())
        with tempfile.TemporaryDirectory() as directory, patch.object(helper, "gh_stream", large_stream), patch.object(helper, "download") as download:
            with self.assertRaisesRegex(ValueError, "size"):
                helper.inspect("owner/repo", directory, True, candidates=True)
            download.assert_not_called()
        with tempfile.TemporaryDirectory() as directory, patch.object(helper, "gh_stream", stream), patch.object(helper, "download") as download, patch.object(helper.time, "monotonic", side_effect=[0, 1, 181]):
            with self.assertRaisesRegex(ValueError, "timed out"):
                helper.inspect("owner/repo", directory, True, candidates=True)
            self.assertEqual(download.call_count, 1)
            self.assertEqual(download.call_args.kwargs["timeout"], 179)

    def test_cache_janitor_removes_only_expired_private_uuid_caches_without_active_owners(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            now = time.time()
            def cache(age, owner=None, mode=0o700):
                path = root / str(uuid.uuid4());path.mkdir(mode=mode)
                archive = path / "update.zip";archive.write_bytes(b"cached archive");archive.chmod(0o600)
                if owner is not None:
                    marker = path / ".owner.json";marker.write_text(json.dumps({"pid": owner}));marker.chmod(0o600)
                os.utime(path, (now - age, now - age))
                return path
            expired = cache(helper.CACHE_TTL + 60)
            recent = cache(60)
            live = cache(helper.CACHE_TTL + 60, owner=os.getpid())
            wrong_mode = cache(helper.CACHE_TTL + 60, mode=0o755)
            unfamiliar = cache(helper.CACHE_TTL + 60)
            (unfamiliar / "published-artifact.zip").write_bytes(b"preserve")
            os.utime(unfamiliar, (now - helper.CACHE_TTL - 60,) * 2)
            link_target = root / "outside";link_target.mkdir();(link_target / "keep").write_bytes(b"preserve")
            (root / str(uuid.uuid4())).symlink_to(link_target, target_is_directory=True)
            self.assertEqual(helper.clean(root, now=now), {"removed": 1})
            self.assertFalse(expired.exists())
            for kept in (recent, live, wrong_mode, unfamiliar, link_target):
                self.assertTrue(kept.exists())
            self.assertEqual((link_target / "keep").read_bytes(), b"preserve")

    def test_release_selection_skips_drafts_and_requires_preview_opt_in(self):
        releases = [self.release("draft", draft=True), self.release("preview", preview=True), self.release("stable")]
        def stream(endpoint, limit, sink, *args, **kwargs):
            sink.write(json.dumps(releases).encode())
        with tempfile.TemporaryDirectory() as directory, patch.object(helper, "gh_stream", stream), patch.object(helper, "download") as download:
            result = helper.inspect("owner/repo", directory, False)
            self.assertEqual(result["tag"], "stable")
            self.assertEqual(result["assets"][0], {"id": 1, "name": "appcast.xml", "size": 20})
            self.assertEqual(stat.S_IMODE(Path(directory).stat().st_mode), 0o700)
            self.assertEqual(helper.inspect("owner/repo", directory, True)["tag"], "preview")
            download.assert_called()

    def test_download_limit_does_not_replace_existing_verified_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text("#!/usr/bin/env python3\nimport sys\nsys.stdout.buffer.write(b'x'*10000)\n")
            gh.chmod(0o700)
            target = root / "cache/update.zip"
            target.parent.mkdir()
            target.write_bytes(b"old verified bytes")
            with patch.dict(os.environ, {"PATH": str(root) + os.pathsep + os.environ["PATH"]}):
                with self.assertRaisesRegex(ValueError, "size"):
                    helper.download("owner/repo", 1, target, 100)
            self.assertEqual(target.read_bytes(), b"old verified bytes")
            self.assertEqual(list(target.parent.glob(".download-*")), [])

    def test_download_is_private_and_keeps_credentials_inside_gh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text("#!/usr/bin/env python3\nimport sys\nassert 'auth' not in sys.argv\nassert '--hostname' in sys.argv\nsys.stdout.buffer.write(b'verified bytes')\n")
            gh.chmod(0o700)
            target = root / "cache/update.zip"
            with patch.dict(os.environ, {"PATH": str(root) + os.pathsep + os.environ["PATH"]}):
                self.assertEqual(helper.download("owner/repo", 1, target, 100), 14)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(target.parent.stat().st_mode), 0o700)

    def test_transport_deadline_terminates_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n")
            gh.chmod(0o700)
            with patch.dict(os.environ, {"PATH": str(root) + os.pathsep + os.environ["PATH"]}):
                with self.assertRaisesRegex(ValueError, "timed out"):
                    helper.gh_stream("repos/owner/repo/releases", 100, io.BytesIO(), timeout=0.1)

    def test_server_exposes_only_two_token_routes_without_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "appcast.xml").write_bytes(b"signed feed bytes")
            (root / "update.zip").write_bytes(b"signed archive bytes")
            (root / "secret").write_bytes(b"private")
            token = "a" * 64
            process = subprocess.Popen([sys.executable, str(HELPER), "serve", "--directory", directory],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                process.stdin.write(json.dumps({"token": token}).encode() + b"\n")
                process.stdin.flush()
                port = json.loads(process.stdout.readline())["port"]
                base = f"http://127.0.0.1:{port}"
                for name in ("appcast.xml", "update.zip"):
                    with urllib.request.urlopen(f"{base}/{token}/{name}", timeout=3) as response:
                        self.assertEqual(response.read(), (root / name).read_bytes())
                for route in ("/appcast.xml", "/wrong/update.zip", f"/{token}/../secret", f"/{token}/secret", f"/{token}/appcast.xml?x=1"):
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(base + route, timeout=3)
                    self.assertEqual(error.exception.code, 404)
                    error.exception.close()
                for headers in ({"Origin": "https://evil.example"}, {"Host": "evil.example"}):
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(urllib.request.Request(f"{base}/{token}/appcast.xml", headers=headers), timeout=3)
                    self.assertEqual(error.exception.code, 403)
                    error.exception.close()
                (root / "update.zip").unlink()
                (root / "update.zip").symlink_to(root / "secret")
                with self.assertRaises(Exception):
                    urllib.request.urlopen(f"{base}/{token}/update.zip", timeout=3)
            finally:
                process.terminate()
                _, stderr = process.communicate(timeout=5)
            self.assertEqual(stderr, b"")

    def test_server_stops_after_its_parent_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            worker = """
import json, os, subprocess, sys, time
p = subprocess.Popen([sys.executable, sys.argv[1], 'serve', '--directory', sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
p.stdin.write(json.dumps({'token': 'b'*64}).encode()+b'\\n'); p.stdin.flush()
print(json.dumps({'pid': p.pid, 'port': json.loads(p.stdout.readline())['port']}), flush=True)
os._exit(0)
"""
            result = subprocess.run([sys.executable, "-c", worker, str(HELPER), directory], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            info = json.loads(result.stdout)
            time.sleep(1.3)
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(f"http://127.0.0.1:{info['port']}/{'b'*64}/appcast.xml", timeout=2)

    def test_server_removes_owned_uuid_cache_after_parent_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / str(uuid.uuid4());cache.mkdir(mode=0o700)
            for name in ("appcast.xml", "update.zip"):
                target = cache / name;target.write_bytes(b"verified bytes");target.chmod(0o600)
            worker = """
import json, os, subprocess, sys
p = subprocess.Popen([sys.executable, sys.argv[1], 'serve', '--directory', sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
p.stdin.write(json.dumps({'token': 'c'*64}).encode()+b'\\n'); p.stdin.flush()
print(p.stdout.readline().decode().strip(), flush=True)
os._exit(0)
"""
            result = subprocess.run([sys.executable, "-c", worker, str(HELPER), str(cache)], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            deadline = time.monotonic() + 4
            while cache.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertFalse(cache.exists())

    @staticmethod
    def release(tag, draft=False, preview=False):
        return {"tag_name": tag, "draft": draft, "prerelease": preview, "published_at": "2026-11-06", "assets": [{"id": 1, "name": "appcast.xml", "size": 20}]}


if __name__ == "__main__":
    unittest.main()
