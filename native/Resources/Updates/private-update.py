#!/usr/bin/env python3
"""Private GitHub release transport. Credentials remain inside the official gh CLI."""
import argparse
import hmac
import http.server
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

FEED_LIMIT = 4 * 1024 * 1024
ARCHIVE_LIMIT = 250 * 1024 * 1024
CANDIDATE_FEED_LIMIT = 1024 * 1024
CACHE_TTL = 48 * 60 * 60


def repository(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value) or any(p in {".", ".."} for p in value.split("/")):
        raise ValueError("Invalid repository.")
    return value


def private_directory(path):
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("Update cache must be an owned directory.")
    path.chmod(0o700)
    return path


def gh_stream(endpoint, limit, sink, accept="application/vnd.github+json", timeout=60):
    gh = shutil.which("gh") or next((str(path) for path in (
        Path("/opt/homebrew/bin/gh"), Path("/usr/local/bin/gh"), Path.home() / ".local/bin/gh")
        if path.is_file() and os.access(path, os.X_OK)), None)
    if not gh:
        raise ValueError("Install GitHub CLI and run gh auth login first.")
    env = dict(os.environ)
    env.pop("GH_DEBUG", None)
    env["GH_PROMPT_DISABLED"] = "1"
    proc = subprocess.Popen([gh, "api", "--hostname", "github.com", "-H", "Accept: " + accept, endpoint],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                            cwd="/", env=env, start_new_session=True)
    count = 0
    deadline = time.monotonic() + timeout
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError("GitHub request timed out. Check your connection and retry.")
            if not selector.select(min(remaining, 1)):
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            count += len(chunk)
            if count > limit:
                raise ValueError("GitHub response exceeded the allowed size.")
            sink.write(chunk)
        proc.wait(timeout=max(0.01, deadline - time.monotonic()))
        if proc.returncode:
            raise ValueError("GitHub request failed. Run gh auth status and check repository access.")
        return count
    finally:
        selector.close()
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        proc.stdout.close()


def download(repo, asset_id, output, maximum, timeout=180):
    if not isinstance(asset_id, int) or isinstance(asset_id, bool) or asset_id <= 0 or not 0 < maximum <= ARCHIVE_LIMIT:
        raise ValueError("Invalid asset or size limit.")
    output = Path(output)
    directory = private_directory(output.parent)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".download-", delete=False) as target:
            temporary = Path(target.name)
            count = gh_stream(f"repos/{repository(repo)}/releases/assets/{asset_id}", maximum, target,
                              "application/octet-stream", timeout=timeout)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, output)
        output.chmod(0o600)
        return count
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def inspect(repo, output_dir, include_prereleases, candidates=False):
    import io
    repo = repository(repo)
    directory = private_directory(output_dir)
    deadline = time.monotonic() + 180
    buffer = io.BytesIO()
    gh_stream(f"repos/{repo}/releases?per_page=30", FEED_LIMIT, buffer, timeout=60)
    releases = json.loads(buffer.getvalue())
    if not isinstance(releases, list):
        raise ValueError("GitHub returned an invalid release list.")
    results = []
    for release in releases[:30]:
        if not isinstance(release, dict) or release.get("draft") is not False or not release.get("published_at"):
            continue
        if release.get("prerelease") is not False and not include_prereleases:
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", tag):
            continue
        raw_assets = release.get("assets", [])
        if not isinstance(raw_assets, list):
            continue
        assets = [{"id": a.get("id"), "name": a.get("name"), "size": a.get("size")}
                  for a in raw_assets if isinstance(a, dict)
                  and type(a.get("id")) is int and a["id"] > 0
                  and isinstance(a.get("name"), str)
                  and type(a.get("size")) is int and a["size"] >= 0]
        feeds = [a for a in assets if a["name"] == "appcast.xml"]
        if len(feeds) != 1:
            continue
        limit = CANDIDATE_FEED_LIMIT if candidates else FEED_LIMIT
        if not 0 < feeds[0]["size"] <= limit:
            raise ValueError("Release feed exceeds the allowed size.")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("Private release inspection timed out. Retry with a working connection.")
        index = len(results)
        feed = directory / str(index) / "appcast.xml" if candidates else directory / "appcast.xml"
        download(repo, feeds[0]["id"], feed, limit, timeout=remaining)
        result = {"tag": tag, "feedPath": str(feed.absolute()), "assets": assets}
        if not candidates:
            return result
        result["index"] = index
        results.append(result)
    if results:
        return {"releases": results}
    raise ValueError("No eligible published release with appcast.xml. Enable preview updates to include prereleases.")


def owned_directory(path):
    try:
        info = Path(path).lstat()
        return stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700
    except OSError:
        return False


def uuid_directory(path):
    try:
        return str(uuid.UUID(Path(path).name)).lower() == Path(path).name.lower() and owned_directory(path)
    except ValueError:
        return False


def active_owner(path):
    try:
        fd = os.open(Path(path) / ".owner.json", os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 1024:
                return True
            pid = json.loads(source.read()).get("pid")
        if type(pid) is not int or pid <= 0:
            return True
        os.kill(pid, 0)
        return True
    except FileNotFoundError:
        return False
    except ProcessLookupError:
        return False
    except (OSError, ValueError, TypeError, AttributeError):
        return True


def remove_cache(path):
    """Remove only the known cache shape; unfamiliar data and symlinks are preserved."""
    path = Path(path)
    if not uuid_directory(path):
        return False
    files, directories = [], []
    try:
        for entry in path.iterdir():
            if entry.name in {"appcast.xml", "update.zip", ".owner.json"} or entry.name.startswith(".download-"):
                info = entry.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                    return False
                files.append(entry)
            elif re.fullmatch(r"(?:[0-9]|[12][0-9])", entry.name) and owned_directory(entry):
                children = list(entry.iterdir())
                for child in children:
                    info = child.lstat()
                    if not (child.name == "appcast.xml" or child.name.startswith(".download-")) or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
                        return False
                files.extend(children)
                directories.append(entry)
            else:
                return False
        for entry in files:
            entry.unlink()
        for entry in directories:
            entry.rmdir()
        path.rmdir()
        return True
    except OSError:
        return False


def clean(directory, now=None):
    root = Path(directory)
    if not root.exists():
        return {"removed": 0}
    if not owned_directory(root):
        raise ValueError("Cache cleanup requires an owned private directory.")
    now = time.time() if now is None else now
    removed = 0
    for child in root.iterdir():
        if uuid_directory(child) and now - child.lstat().st_mtime > CACHE_TTL and not active_owner(child):
            removed += int(remove_cache(child))
    return {"removed": removed}


def serve(directory):
    parent_pid = os.getppid()
    directory = private_directory(directory)
    line = sys.stdin.buffer.readline(1025)
    if len(line) > 1024:
        raise ValueError("Invalid local update token.")
    token = json.loads(line).get("token")
    if not isinstance(token, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", token):
        raise ValueError("Invalid local update token.")
    owner_fd = os.open(directory / ".owner.json", os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(owner_fd, "w") as owner:
        json.dump({"pid": os.getpid()}, owner)
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, *args):
            pass

        def do_HEAD(self):
            self.transfer(False)

        def do_GET(self):
            self.transfer(True)

        def transfer(self, body):
            if self.headers.get("Origin") is not None or self.headers.get("Host") != f"127.0.0.1:{self.server.server_port}":
                self.send_error(403)
                return
            route = next((name for name in ("appcast.xml", "update.zip")
                          if hmac.compare_digest(self.path.encode("utf-8"), f"/{token}/{name}".encode("ascii"))), None)
            if route is None:
                self.send_error(404)
                return
            try:
                fd = os.open(directory / route, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(fd, "rb") as source:
                    info = os.fstat(source.fileno())
                    limit = FEED_LIMIT if route == "appcast.xml" else ARCHIVE_LIMIT
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or not 0 < info.st_size <= limit:
                        self.send_error(404)
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", "application/xml" if route == "appcast.xml" else "application/octet-stream")
                    self.send_header("Content-Length", str(info.st_size))
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    if body:
                        shutil.copyfileobj(source, self.wfile, length=65536)
            except (OSError, TimeoutError):
                self.close_connection = True

    class Server(http.server.HTTPServer):
        request_queue_size = 4

        def handle_error(self, request, client_address):
            pass

    server = Server(("127.0.0.1", 0), Handler)
    server.timeout = 1
    print(json.dumps({"port": server.server_port}), flush=True)
    try:
        while running and os.getppid() == parent_pid:
            server.handle_request()
    finally:
        server.server_close()
        remove_cache(directory)


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("inspect")
    check.add_argument("--repository", required=True)
    check.add_argument("--output-dir", required=True)
    check.add_argument("--include-prereleases", action="store_true")
    check.add_argument("--candidates", action="store_true")
    fetch = commands.add_parser("download")
    fetch.add_argument("--repository", required=True)
    fetch.add_argument("--asset-id", type=int, required=True)
    fetch.add_argument("--output", required=True)
    fetch.add_argument("--max-bytes", type=int, required=True)
    local = commands.add_parser("serve")
    local.add_argument("--directory", required=True)
    cleanup = commands.add_parser("clean")
    cleanup.add_argument("--directory", required=True)
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            result = inspect(args.repository, args.output_dir, args.include_prereleases, args.candidates)
        elif args.command == "download":
            result = {"bytes": download(args.repository, args.asset_id, args.output, args.max_bytes)}
        elif args.command == "clean":
            result = clean(args.directory)
        else:
            serve(args.directory)
            return
        print(json.dumps(result), flush=True)
    except Exception as error:
        # Never include subprocess output, command lines, or credential material.
        message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "Private update transport failed. Check GitHub CLI sign-in and retry."
        print(json.dumps({"error": message}), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
