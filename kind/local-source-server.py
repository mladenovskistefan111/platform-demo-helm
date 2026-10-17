#!/usr/bin/env python3
"""HTTP server for kind/local-source.sh: static files plus Git over "smart" HTTP (clone/fetch only).

Argo CD's Git client (go-git) cannot read a repository over the "dumb" protocol that `python -m http.server` offers, so
`/git/<name>.git/...` is answered by `git upload-pack --stateless-rpc`; everything else is served from the directory as files.

    local-source-server.py <bind-address> <port> <directory>
"""
import gzip
import os
import subprocess
import sys
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BIND, PORT, ROOT = sys.argv[1], int(sys.argv[2]), os.path.abspath(sys.argv[3])
GIT_ROOT = os.path.join(ROOT, "git")


def repo_path(url_path: str):
    """/git/<name>.git/<rest> -> (absolute repository path, rest); None if it does not name a repository below GIT_ROOT."""
    parts = url_path.split("/")
    if len(parts) < 4 or parts[1] != "git" or not parts[2].endswith(".git"):
        return None
    path = os.path.realpath(os.path.join(GIT_ROOT, parts[2]))
    if os.path.dirname(path) != os.path.realpath(GIT_ROOT) or not os.path.isdir(path):
        return None
    return path, "/".join(parts[3:])


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _git_env(self):
        env = dict(os.environ)
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        return env

    def do_GET(self):
        u = urlparse(self.path)
        r = repo_path(u.path)
        if r and r[1] == "info/refs":
            if parse_qs(u.query).get("service") != ["git-upload-pack"]:
                return self.send_error(HTTPStatus.FORBIDDEN, "only git-upload-pack (clone and fetch) is served")
            out = subprocess.run(["git", "upload-pack", "--stateless-rpc", "--advertise-refs", r[0]],
                                 capture_output=True, env=self._git_env(), check=True).stdout
            head = b"" if self.headers.get("Git-Protocol", "").endswith("version=2") else b"001e# service=git-upload-pack\n0000"
            return self._send(out, "application/x-git-upload-pack-advertisement", prefix=head)
        return super().do_GET()

    def do_POST(self):
        r = repo_path(urlparse(self.path).path)
        if not (r and r[1] == "git-upload-pack"):
            return self.send_error(HTTPStatus.FORBIDDEN)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        out = subprocess.run(["git", "upload-pack", "--stateless-rpc", r[0]], input=body, capture_output=True,
                             env=self._git_env(), check=True).stdout
        self._send(out, "application/x-git-upload-pack-result")

    def _send(self, data: bytes, ctype: str, prefix: bytes = b""):
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(prefix) + len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(prefix + data)


ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
