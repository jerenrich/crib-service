#!/usr/bin/env python3
"""Local server for the Calibration Lab.

Serves the page and fetches the Listener's sound-analysis logs and saved audio
from the phone on demand with `xcrun devicectl`, caching them in ./data
(git-ignored). Binds to 127.0.0.1 only; nothing leaves this Mac.

    python3 scripts/calibration-lab/server.py --device <listener UDID or name>

The device can also come from CRIB_LISTENER_DEVICE. Without a reachable phone
the page still works from whatever is already cached.
"""
import argparse
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
STATIC = {"/": "index.html", "/index.html": "index.html", "/app.js": "app.js",
          "/detector.js": "detector.js", "/parse.js": "parse.js",
          "/engine.js": "engine.js"}
KINDS = {
    "sound": ("Library/Application Support/sound-analysis",
              re.compile(r"^sound-\d{4}-\d{2}-\d{2}-(\d{13})-[0-9a-f-]{36}\.csv$")),
    "audio": ("Library/Application Support/CalibrationAudio",
              re.compile(r"^(\d{13})-[0-9A-F-]{36}\.m4a$")),
}
LISTING_TTL = 60
GROWING_TTL = 90  # refetch the newest sound log once it is this stale


class Device:
    def __init__(self, device, bundle):
        self.device, self.bundle = device, bundle
        self.listings = {}
        self.refreshing = set()
        self.locks = {}
        self.guard = threading.Lock()

    def _run(self, args, attempts=3):
        last = None
        for attempt in range(attempts):
            proc = subprocess.run(["xcrun", "devicectl", *args, "--device", self.device,
                                   "--domain-type", "appDataContainer", "--domain-identifier", self.bundle],
                                  capture_output=True, text=True, timeout=180)
            if proc.returncode == 0:
                return
            last = (proc.stderr or proc.stdout).strip().splitlines()[-1:] or ["devicectl failed"]
            time.sleep(1 + attempt)
        raise RuntimeError(last[0])

    def lock(self, key):
        with self.guard:
            return self.locks.setdefault(key, threading.Lock())

    def listing(self, kind, wait=True):
        """The phone's file list. Once one exists, an expired list is returned at
        once and refreshed in the background, so clicks never wait on the phone."""
        with self.lock("list:" + kind):
            cached = self.listings.get(kind)
            if cached and time.time() - cached[0] < LISTING_TTL:
                return cached[1], cached[2]
            if cached and not wait:
                if kind not in self.refreshing:
                    self.refreshing.add(kind)
                    threading.Thread(target=self._refresh, args=(kind,), daemon=True).start()
                return cached[1], cached[2]
            return self._load_listing(kind)

    def _refresh(self, kind):
        try:
            self._load_listing(kind)  # no lock held: readers keep using the old list
        finally:
            self.refreshing.discard(kind)

    def _load_listing(self, kind):
        folder, pattern = KINDS[kind]
        try:
            if not self.device:
                raise RuntimeError("no device configured")
            with tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "ls.json"
                self._run(["device", "info", "files", "--subdirectory", folder, "--json-output", str(out)])
                files = json.loads(out.read_text())["result"]["files"]
            items = [{"name": f["name"], "start": int(m.group(1)) / 1000, "size": f["metadata"]["size"]}
                     for f in files if (m := pattern.match(f["name"]))]
            error = None
        except Exception as exc:  # fall back to the cache
            items, error = [], str(exc)
            for path in (DATA / kind).glob("*"):
                if m := pattern.match(path.name):
                    items.append({"name": path.name, "start": int(m.group(1)) / 1000, "size": path.stat().st_size})
        items.sort(key=lambda i: i["start"])
        self.listings[kind] = (time.time(), items, error)
        return items, error

    def fetch(self, kind, name):
        folder, pattern = KINDS[kind]
        if not pattern.match(name):
            raise FileNotFoundError(name)
        target = DATA / kind / name
        with self.lock(f"{kind}:{name}"):
            if target.exists():
                if kind == "audio":
                    return target
                items, error = self.listing(kind, wait=False)
                newest = items[-1]["name"] if items else None
                remote = next((i for i in items if i["name"] == name), None)
                fresh = time.time() - target.stat().st_mtime < GROWING_TTL
                if not (error or name != newest or fresh or (remote and remote["size"] == target.stat().st_size)):
                    # The log the phone is still writing: serve what we have and
                    # pull the newer copy in the background for the next request.
                    if self.device and target not in self.refreshing:
                        self.refreshing.add(target)
                        threading.Thread(target=self._refetch, args=(folder, name, target), daemon=True).start()
                return target
            if not self.device:
                raise FileNotFoundError(name)
            self._copy(folder, name, target)
            return target

    def _copy(self, folder, name, target):
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(target.suffix + f".{threading.get_ident()}.part")
        self._run(["device", "copy", "from", "--source", f"{folder}/{name}", "--destination", str(partial)])
        os.replace(partial, target)

    def _refetch(self, folder, name, target):
        try:
            self._copy(folder, name, target)
        except Exception:
            pass  # keep the cached copy
        finally:
            self.refreshing.discard(target)


class Handler(SimpleHTTPRequestHandler):
    device: Device = None

    def log_message(self, fmt, *args):
        if "/api/" in (self.path or ""):
            super().log_message(fmt, *args)

    def send_json(self, value, status=HTTPStatus.OK):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, content_type):
        size = path.stat().st_size
        start, end = 0, size - 1
        ranged = self.headers.get("Range", "")
        m = re.match(r"bytes=(\d*)-(\d*)$", ranged)
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else end
            else:
                start = max(0, size - int(m.group(2)))
            end = min(end, size - 1)
            self.send_response(HTTPStatus.PARTIAL_CONTENT)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Cache-Control", "max-age=3600" if content_type == "audio/mp4" else "no-store")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(1 << 16, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def do_PUT(self):
        if urlparse(self.path).path != "/api/labels":
            return self.send_error(HTTPStatus.NOT_FOUND)
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"[]")
            labels = [{"t": float(l["t"]), "kind": l["kind"]} for l in body if l.get("kind") in ("cry", "noise")]
        except (ValueError, KeyError, TypeError, AttributeError):
            return self.send_json({"error": "expected [{t, kind}]"}, HTTPStatus.BAD_REQUEST)
        DATA.mkdir(parents=True, exist_ok=True)
        tmp = DATA / "labels.json.part"
        tmp.write_text(json.dumps(sorted(labels, key=lambda l: l["t"]), indent=1))
        os.replace(tmp, DATA / "labels.json")
        self.send_json({"saved": len(labels)})

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        try:
            if path in STATIC:
                name = STATIC[path]
                kind = "text/html" if name.endswith(".html") else "text/javascript"
                return self.send_file(ROOT / name, kind + "; charset=utf-8")
            if path == "/api/labels":
                labels = DATA / "labels.json"
                return self.send_json(json.loads(labels.read_text()) if labels.exists() else [])
            if path == "/api/files":
                sound, sound_error = self.device.listing("sound", wait=False)
                audio, audio_error = self.device.listing("audio", wait=False)
                return self.send_json({"sound": sound, "audio": audio, "offline": bool(sound_error),
                                       "error": sound_error or audio_error})
            if m := re.match(r"^/api/(sound|audio)/([^/]+)$", path):
                kind, name = m.groups()
                target = self.device.fetch(kind, name)
                return self.send_file(target, "text/csv; charset=utf-8" if kind == "sound" else "audio/mp4")
            self.send_error(HTTPStatus.NOT_FOUND)
        except FileNotFoundError:
            self.send_json({"error": "not available"}, HTTPStatus.NOT_FOUND)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.send_json({"error": str(exc)}, HTTPStatus.BAD_GATEWAY)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", default=os.environ.get("CRIB_LISTENER_DEVICE"),
                        help="Listener UDID or name (default: $CRIB_LISTENER_DEVICE)")
    parser.add_argument("--bundle", default="com.jordanerenrich.cribservice")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    Handler.device = Device(args.device, args.bundle)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Calibration Lab on http://127.0.0.1:{args.port} (device: {args.device or 'none, cache only'})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
