#!/usr/bin/env python3
"""Local server for the Calibration Lab.

Serves the page and fetches the Listener's sound-analysis logs and saved audio
from the phone on demand with `xcrun devicectl`, caching them in ./data
(git-ignored). Binds to 127.0.0.1 and only answers requests addressed to it;
nothing leaves this Mac.

    python3 scripts/calibration-lab/server.py --device <listener UDID or name>

The device can also come from CRIB_LISTENER_DEVICE. Without a reachable phone
the page still works from whatever is already cached.
"""
import argparse
import json
import math
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
GROWING_TTL = 90  # don't refetch a cached file more often than this
LABELS = DATA / "labels.json"
LABELS_LOCK = threading.Lock()


class Device:
    def __init__(self, device, bundle):
        self.device, self.bundle = device, bundle
        self.listings = {}
        self.refreshing = set()
        self.locks = {}
        self.guard = threading.Lock()

    def _run(self, args, attempts=3):
        last = "devicectl failed"
        for attempt in range(attempts):
            if attempt:
                time.sleep(attempt)  # back off between attempts, not after the last one
            try:
                proc = subprocess.run(["xcrun", "devicectl", *args, "--device", self.device,
                                       "--domain-type", "appDataContainer", "--domain-identifier", self.bundle],
                                      capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired:
                last = "devicectl timed out"
                continue
            if proc.returncode == 0:
                return
            last = ((proc.stderr or proc.stdout).strip().splitlines() or [last])[-1]
        raise RuntimeError(last)

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
        except Exception as exc:  # phone unreachable: the cache below is all there is
            items, error = [], str(exc)
        # Files the phone has since pruned stay usable from the cache.
        on_phone = {i["name"] for i in items}
        for path in (DATA / kind).glob("*"):
            if path.name not in on_phone and (m := pattern.match(path.name)):
                items.append({"name": path.name, "start": int(m.group(1)) / 1000, "size": path.stat().st_size,
                              "cached_only": True})
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
                items, error = self.listing(kind, wait=False)
                remote = next((i for i in items if i["name"] == name and not i.get("cached_only")), None)
                stat = target.stat()
                if (error or not self.device or remote is None or remote["size"] == stat.st_size
                        or time.time() - stat.st_mtime < GROWING_TTL):
                    return target
                # The phone's copy differs from ours: it was still being written when
                # we cached it. The newest file is still growing, so serve what we
                # have and refresh it in the background; anything else is finished on
                # the phone now, so fetch it once before serving.
                newest = next((i["name"] for i in reversed(items) if not i.get("cached_only")), None)
                if name == newest:  # the log, or audio segment, the phone is writing now
                    if target not in self.refreshing:
                        self.refreshing.add(target)
                        threading.Thread(target=self._refetch, args=(folder, name, target), daemon=True).start()
                    return target
                try:
                    self._copy(folder, name, target)
                except Exception:
                    pass  # keep serving the cached copy
                return target
            if not self.device:
                raise FileNotFoundError(name)
            self._copy(folder, name, target)
            return target

    def _copy(self, folder, name, target):
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(target.suffix + f".{threading.get_ident()}.part")
        try:
            self._run(["device", "copy", "from", "--source", f"{folder}/{name}", "--destination", str(partial)])
            os.replace(partial, target)
        finally:
            partial.unlink(missing_ok=True)  # a failed or interrupted copy leaves nothing behind

    def _refetch(self, folder, name, target):
        try:
            self._copy(folder, name, target)
        except Exception:
            pass  # keep the cached copy
        finally:
            self.refreshing.discard(target)


_run_cache, _run_lock = {}, threading.Lock()  # file name -> (bytes scanned, {run: info})
RUN_ID = re.compile(rb"^[^,]*,([0-9a-f-]{36}),")
THRESHOLD = re.compile(rb"confidence_threshold=([0-9.]+)")


def _scan_runs(data, found):
    """Add run markers from complete lines in `data` to `found`: whether a
    run_start named an alert policy, and the first confidence_threshold seen.
    Searches for the markers directly; lines that don't parse are skipped."""
    lines = set()
    for marker in (b",run_start,", b"confidence_threshold="):
        i = data.find(marker)
        while i >= 0:
            lines.add(data.rfind(b"\n", 0, i) + 1)
            nl = data.find(b"\n", i)
            i = data.find(marker, nl) if nl >= 0 else -1
    for start in sorted(lines):
        end = data.find(b"\n", start)
        line = data[start:end if end >= 0 else len(data)]
        run = RUN_ID.match(line)
        if not run:
            continue
        info = found.setdefault(run.group(1).decode("ascii"), {})
        if b",run_start," in line:
            info["policy"] = info.get("policy", False) or b"alert_policy=" in line
        mark = THRESHOLD.search(line)
        if mark and "threshold" not in info:
            try:
                info["threshold"] = float(mark.group(1))
            except ValueError:
                pass


def run_index():
    """Per run id, from every cached sound log: its classifier threshold marker
    (if any row logged one) and whether its run_start carried an alert policy.
    A night's own files often don't include its run's start, so the replay asks
    for this instead. Each file is scanned once; a growing log only from where
    the last scan stopped."""
    runs = {}
    with _run_lock:
        for path in sorted((DATA / "sound").glob("sound-*.csv")):
            size = path.stat().st_size
            scanned, found = _run_cache.get(path.name, (0, {}))
            if size < scanned:  # replaced by a shorter copy: start again
                scanned, found = 0, {}
            if size > scanned:
                with open(path, "rb") as f:
                    f.seek(scanned)
                    chunk = f.read(size - scanned)
                end = chunk.rfind(b"\n") + 1  # only complete lines; the rest waits for more data
                found = {k: dict(v) for k, v in found.items()}
                _scan_runs(chunk[:end], found)
                scanned += end
                _run_cache[path.name] = (scanned, found)
            for run, info in found.items():
                merged = runs.setdefault(run, {"threshold": None, "policy": False})
                if merged["threshold"] is None and info.get("threshold") is not None:
                    merged["threshold"] = info["threshold"]
                merged["policy"] = merged["policy"] or info.get("policy", False)
    return runs


def read_labels():
    return json.loads(LABELS.read_text()) if LABELS.exists() else []


def apply_label_ops(labels, ops):
    """Apply [{op: 'set', t, kind} | {op: 'delete', t}] to a label list."""
    for op in ops:
        t = float(op["t"])
        if not math.isfinite(t):  # json.loads accepts NaN, which would match no label and drop them all
            raise ValueError("t must be a finite number")
        labels = [l for l in labels if abs(l["t"] - t) > 1e-3]
        if op["op"] == "set":
            if op.get("kind") not in ("cry", "noise"):
                raise ValueError("kind must be cry or noise")
            labels.append({"t": t, "kind": op["kind"]})
        elif op["op"] != "delete":
            raise ValueError("unknown op")
    return sorted(labels, key=lambda l: l["t"])


class Handler(SimpleHTTPRequestHandler):
    device: Device = None
    port: int = 0

    def allowed(self):
        """Only answer requests addressed to this machine, so a web page that
        rebinds its own hostname to 127.0.0.1 can't read nursery audio or labels."""
        hosts = {f"127.0.0.1:{self.port}", f"localhost:{self.port}", f"[::1]:{self.port}"}
        origin = self.headers.get("Origin")
        if self.headers.get("Host", "") in hosts and (origin is None or origin.split("://", 1)[-1] in hosts):
            return True
        self.send_json({"error": "forbidden host"}, HTTPStatus.FORBIDDEN)
        return False

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
            if start > end:  # past the end, or 'bytes=-0', or an empty file
                self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
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

    def do_POST(self):
        """Label changes arrive as operations and are applied to the stored list
        under a lock, so overlapping saves (or two open pages) can't undo each other."""
        if not self.allowed():
            return
        if urlparse(self.path).path != "/api/labels":
            return self.send_error(HTTPStatus.NOT_FOUND)
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
            with LABELS_LOCK:
                labels = apply_label_ops(read_labels(), body["ops"])
                DATA.mkdir(parents=True, exist_ok=True)
                tmp = LABELS.with_suffix(f".{threading.get_ident()}.part")
                tmp.write_text(json.dumps(labels, indent=1))
                os.replace(tmp, LABELS)
        except (ValueError, KeyError, TypeError, AttributeError) as exc:
            return self.send_json({"error": f"expected {{ops: [...]}}: {exc}"}, HTTPStatus.BAD_REQUEST)
        self.send_json(labels)

    def do_GET(self):
        if not self.allowed():
            return
        path = unquote(urlparse(self.path).path)
        try:
            if path in STATIC:
                name = STATIC[path]
                kind = "text/html" if name.endswith(".html") else "text/javascript"
                return self.send_file(ROOT / name, kind + "; charset=utf-8")
            if path == "/api/labels":
                with LABELS_LOCK:
                    return self.send_json(read_labels())
            if path == "/api/runs":
                return self.send_json(run_index())
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
    Handler.port = args.port
    threading.Thread(target=run_index, daemon=True).start()  # warm the run index
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Calibration Lab on http://127.0.0.1:{args.port} (device: {args.device or 'none, cache only'})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
