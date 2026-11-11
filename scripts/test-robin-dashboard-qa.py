#!/usr/bin/env python3
"""Isolated loopback server checks; no API calls or real ledger/choice writes."""
import importlib.util
import json
import pathlib
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

repo = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("robin_dashboard_qa", repo / "output/robin-brain-picker/serve.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="robin-dashboard-qa-") as folder:
    module.ROOT = pathlib.Path(folder)
    (module.ROOT / "index.html").write_text("<title>QA fixture</title>")
    module.LEDGER = module.ROOT / "ledger.json"
    module.LEDGER.write_text(json.dumps([{"id": "fixture", "actualModelID": "local", "credential": "never-serve", "prompt": "never-serve"}]))
    server = ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
    module.HOST = "127.0.0.1:" + str(server.server_port)
    origin = "http://" + module.HOST
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    def request(path, method="GET", body=None, headers=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(origin + path, data=data, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()
    try:
        status, data = request("/metrics")
        assert status == 200
        assert b"never-serve" not in data and b"credential" not in data and b"prompt" not in data
        assert json.loads(data)["records"][0]["actualModelID"] == "local"
        assert request("/serve.py")[0] == 404
        assert request("/metrics", headers={"Host": "evil.example"})[0] == 403
        assert request("/choice", "POST", {"model": "local", "intentOnly": True})[0] == 403
        assert request("/choice", "POST", [], {"Origin": origin})[0] == 400
        assert request("/choice", "POST", {"model": "local", "intentOnly": False}, {"Origin": origin})[0] == 400
        assert not (module.ROOT / "choice.json").exists()
        print("PASS: isolated dashboard origin/host/path guards and content-free metrics; no real choice or ledger changed.")
    finally:
        server.shutdown()
        server.server_close()
