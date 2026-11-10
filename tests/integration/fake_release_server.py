#!/usr/bin/env python3
# Copyright (c) 2026 Costas Kirgoussios
#
# This software is licensed under the PolyForm Noncommercial License 1.0.0.
# You may obtain a copy of the License at:
# https://polyformproject.org/licenses/noncommercial/1.0.0/

"""Fake release server for the setup.sh network tests. Test-only, standard library only, loopback only.

Usage: fake_release_server.py PORT SCENARIO.json

PORT 0 picks a free port; the server prints "PORT <n>" on stdout once it is listening.

The scenario maps a path to a list of responses, consumed in order, one per GET:
  {"status": 504}
  {"status": 429, "headers": {"Retry-After": "1"}}
  {"status": 200, "body_file": "/abs/or/scenario-relative/file", "truncate": N}
  {"status": 302, "location": "{base}/next"}       ({base} becomes http://127.0.0.1:PORT)
  {"status": 200, "head_status": 405}               (HEAD answers 405; GET answers 200)
  {"status": 200, "body_file": "f", "hang_after": N} (GET sends N body bytes of the promised length, then stalls
                                                       for 30 seconds)
  {"status": 200, "body_file": "f", "content_length": N} (the Content-Length header says N instead of the body
                                                       size, so a HEAD can report a large file without
                                                       one; use it only for paths that are never fetched)
A HEAD request is answered from the next unconsumed response without consuming or counting it, so a
resolve step does not use up the responses meant for the download. A path whose list is exhausted, or
that is not in the scenario, answers 410.
GET /__count/<path> answers with the number of GET requests that hit /<path>.
GET /__countprefix/<prefix> answers with the number of GET requests whose path starts with /<prefix>.
"""

import http.server
import json
import os
import socketserver
import sys
import threading
import time


class State:
    lock = threading.Lock()
    scenario = {}
    base_dir = "."
    counts = {}
    cursor = {}
    base = ""


def next_response(path, consume):
    with State.lock:
        responses = State.scenario.get(path, [])
        index = State.cursor.get(path, 0)
        if consume:
            State.counts[path] = State.counts.get(path, 0) + 1
            State.cursor[path] = index + 1
        if index < len(responses):
            return responses[index]
        return {"status": 410}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "fake-release/1"

    def log_message(self, format, *args):
        pass

    def reply(self, spec, head):
        status = spec.get("status", 200)
        if head and "head_status" in spec:
            status = spec["head_status"]
        body = b""
        if "body_file" in spec and status == 200:
            path = os.path.join(State.base_dir, spec["body_file"])
            with open(path, "rb") as handle:
                body = handle.read()
        self.send_response(status)
        for name, value in spec.get("headers", {}).items():
            self.send_header(name, value)
        if "location" in spec:
            self.send_header("Location", spec["location"].replace("{base}", State.base))
        self.send_header("Content-Length", str(spec.get("content_length", len(body))))
        self.send_header("Connection", "close")
        self.end_headers()
        if head:
            return
        cut = spec.get("truncate")
        stall = spec.get("hang_after")
        if stall is not None:
            self.wfile.write(body[:stall])
            self.wfile.flush()
            time.sleep(30)
            return
        self.wfile.write(body if cut is None else body[:cut])
        self.wfile.flush()
        self.close_connection = True

    def do_HEAD(self):
        self.reply(next_response(self.path, False), True)

    def do_GET(self):
        if self.path.startswith("/__countprefix/"):
            prefix = "/" + self.path[len("/__countprefix/"):]
            with State.lock:
                body = str(sum(n for k, n in State.counts.items() if k.startswith(prefix))).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/__count/"):
            target = "/" + self.path[len("/__count/"):]
            with State.lock:
                body = str(State.counts.get(target, 0)).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.reply(next_response(self.path, True), False)


class Server(http.server.ThreadingHTTPServer):
    """HTTPServer.server_bind asks socket.getfqdn() for the bound address, a reverse DNS lookup that takes
    longer than the tests wait for the PORT line on the macOS runners; nothing here uses the name."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    scenario_file = sys.argv[2]
    with open(scenario_file, encoding="utf-8") as handle:
        State.scenario = json.load(handle)
    State.base_dir = os.path.dirname(os.path.abspath(scenario_file))
    server = Server(("127.0.0.1", int(sys.argv[1])), Handler)
    State.base = "http://127.0.0.1:%d" % server.server_address[1]
    sys.stdout.write("PORT %d\n" % server.server_address[1])
    sys.stdout.flush()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
