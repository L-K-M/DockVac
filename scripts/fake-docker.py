#!/usr/bin/env python3
"""Serve captured Docker Engine API fixtures over a unix socket.

Lets DockVac run without Docker, for demos, screenshots, and UI smoke tests:

    scripts/fake-docker.py --socket /tmp/dockvac-fake.sock &
    DOCKER_HOST=unix:///tmp/dockvac-fake.sock build/DockVac.app/Contents/MacOS/DockVac

Reads respond with the JSON under Tests/DockVacCoreTests/Fixtures. Removals answer the
way a daemon would (204 for containers and volumes, a Deleted list for images, a
CachesDeleted list for build cache) without touching anything. `--delay` slows every
response down so the scanning screen stays visible for a while.
"""

import argparse
import json
import os
import signal
import socketserver
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FIXTURES = REPOSITORY_ROOT / "Tests" / "DockVacCoreTests" / "Fixtures"


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    fixtures = DEFAULT_FIXTURES
    delay = 0.0
    log = False
    # Test hooks: tag -> image ID overrides for inspect, path substrings that fail with 409,
    # and a file that records every request line.
    repointed = {}
    fail_delete = []
    request_log = None

    def _record(self):
        if self.request_log:
            with open(self.request_log, "a") as handle:
                handle.write("%s %s\n" % (self.command, self.path))

    def _image_id(self, reference):
        """Resolve a tag, digest, or ID prefix against the image fixture."""
        if reference in self.repointed:
            return self.repointed[reference]
        images = json.loads(self._fixture("system_df_image.json"))["Images"]
        for image in images:
            if reference in (image.get("RepoTags") or []) or reference in (image.get("RepoDigests") or []):
                return image["Id"]
            bare = image["Id"].split(":", 1)[1]
            if reference == image["Id"] or bare.startswith(reference.replace("sha256:", "")):
                return image["Id"]
        return None

    def log_message(self, format, *args):  # noqa: A002 - matches BaseHTTPRequestHandler
        if self.log:
            sys.stderr.write("%s %s\n" % (self.command, self.path))

    # Docker's own headers, so the client sees a realistic daemon.
    def _headers(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Api-Version", "1.54")
        self.send_header("Builder-Version", "2")
        self.send_header("Ostype", "linux")
        self.send_header("Server", "Docker/29.3.1 (fake)")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _fixture(self, name):
        return (self.fixtures / name).read_bytes()

    def _json(self, status, payload):
        self._headers(status, json.dumps(payload).encode())

    def do_GET(self):
        self._record()
        if self.delay:
            time.sleep(self.delay)
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        path = url.path
        if "/images/" in path and path.endswith("/json"):
            reference = urllib.parse.unquote(path.split("/images/", 1)[1][: -len("/json")])
            image_id = self._image_id(reference)
            if image_id is None:
                return self._json(404, {"message": "No such image: %s" % reference})
            return self._json(200, {"Id": image_id, "RepoTags": [reference]})
        if path.endswith("/_ping"):
            return self._headers(200, b"OK", "text/plain; charset=utf-8")
        if path.endswith("/version"):
            return self._headers(200, self._fixture("version.json"))
        if path.endswith("/containers/json"):
            return self._headers(200, self._fixture("containers_json_all_size.json"))
        if path.endswith("/images/json"):
            return self._headers(200, self._fixture("images_json_all_shared.json"))
        if path.endswith("/volumes"):
            return self._headers(200, self._fixture("volumes.json"))
        if path.endswith("/system/df"):
            kind = query.get("type", [None])[0]
            names = {
                None: "system_df.json",
                "image": "system_df_image.json",
                "container": "system_df_container.json",
                "volume": "system_df_volume.json",
                "build-cache": "system_df_build_cache.json",
            }
            if kind in names:
                return self._headers(200, self._fixture(names[kind]))
            return self._json(400, {"message": "invalid type %s" % kind})
        return self._json(404, {"message": "page not found"})

    def do_DELETE(self):
        self._record()
        if self.delay:
            time.sleep(self.delay)
        path = urllib.parse.urlsplit(self.path).path
        if any(pattern in path for pattern in self.fail_delete):
            return self._json(409, {"message": "conflict: simulated by fake-docker --fail-delete"})
        if "/containers/" in path or "/volumes/" in path:
            return self._headers(204, b"")
        if "/images/" in path:
            reference = urllib.parse.unquote(path.rsplit("/images/", 1)[1])
            return self._json(200, [{"Untagged": reference}, {"Deleted": "sha256:" + "0" * 64}])
        return self._json(404, {"message": "page not found"})

    def do_POST(self):
        self._record()
        if self.delay:
            time.sleep(self.delay)
        url = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if url.path.endswith("/build/prune"):
            filters = urllib.parse.parse_qs(url.query).get("filters", ["{}"])[0]
            try:
                ids = json.loads(filters).get("id", [])
            except json.JSONDecodeError:
                ids = []
            return self._json(200, {"CachesDeleted": ids, "SpaceReclaimed": 600000 * len(ids)})
        return self._json(404, {"message": "page not found"})


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", default="/tmp/dockvac-fake.sock")
    parser.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES)
    parser.add_argument("--delay", type=float, default=0.0, help="seconds to wait before each response")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument(
        "--repoint", action="append", default=[], metavar="TAG=IMAGE_ID",
        help="make inspect report a different image for TAG (simulates a tag moved after the scan)")
    parser.add_argument(
        "--fail-delete", action="append", default=[], metavar="SUBSTRING",
        help="answer DELETE requests whose path contains SUBSTRING with 409")
    parser.add_argument("--request-log", help="append one 'METHOD PATH' line per request to this file")
    arguments = parser.parse_args()

    if os.path.exists(arguments.socket):
        os.unlink(arguments.socket)
    FixtureHandler.fixtures = arguments.fixtures
    FixtureHandler.delay = arguments.delay
    FixtureHandler.log = arguments.verbose
    FixtureHandler.repointed = dict(entry.split("=", 1) for entry in arguments.repoint)
    FixtureHandler.fail_delete = arguments.fail_delete
    FixtureHandler.request_log = arguments.request_log

    server = UnixServer(arguments.socket, FixtureHandler)
    # Test runners may spawn us with SIGTERM ignored; handle it explicitly so `kill` works.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    print("fake docker daemon listening on unix://%s" % arguments.socket, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if os.path.exists(arguments.socket):
            os.unlink(arguments.socket)


if __name__ == "__main__":
    main()
