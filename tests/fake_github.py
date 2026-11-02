"""A local stand-in for api.github.com, github.com's device flow and the
marketplace stats API. The plugin reaches it through HOWISMYPLUG_TEST_BASE
(only http://127.0.0.1:<port> is accepted). Every request is logged with its
Authorization header so tests can check where the token went."""

import base64
import json
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "ghu_testtoken0123456789abcdefABCDEF"
PAT = "github_pat_11TESTONLY0123456789_abcdefghijklmnop"
PAT2 = "github_pat_22TESTONLY9876543210_zyxwvutsrqponmlkj"


def day_series(kind, days):
    """days: {"2026-10-30": (count, uniques)} -> GitHub's response shape."""
    return {
        "count": sum(c for c, _ in days.values()),
        "uniques": max([u for _, u in days.values()] or [0]),
        kind: [{"timestamp": d + "T00:00:00Z", "count": c, "uniques": u} for d, (c, u) in sorted(days.items())],
    }


class Fake:
    def __init__(self):
        self.repos = {}        # "owner/repo" -> {"clones": {...}, "views": {...}, "manifest": dict|None, "access": bool}
        self.market = {}       # plugin id -> {"views", "copies", "hearts"}
        self.requests = []     # (method, path, authorization header)
        self.token_polls = 0
        self.pending_polls = 0  # how many polls answer "authorization_pending" first
        self.hang_polls = 0     # how many token polls never answer (a stalled connection)
        self.valid_tokens = {TOKEN, PAT, PAT2}
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.server.daemon_threads = True    # a hung request must not hold up teardown
        self.server.block_on_close = False
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def base(self):
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send(self, status, body):
                data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(length)
                fake.requests.append(("POST", self.path, self.headers.get("Authorization")))
                if self.path == "/login/login/device/code":
                    return self.send(200, {"device_code": "dc0123456789", "user_code": "ABCD-1234",
                                           "verification_uri": "https://github.com/login/device",
                                           "expires_in": 900, "interval": 5})
                if self.path == "/login/login/oauth/access_token":
                    fake.token_polls += 1
                    if fake.token_polls <= fake.hang_polls:
                        time.sleep(30)  # longer than the plugin's timeout; it gives up first
                        return
                    if fake.token_polls <= fake.pending_polls:
                        return self.send(200, {"error": "authorization_pending"})
                    return self.send(200, {"access_token": TOKEN, "token_type": "bearer", "scope": ""})
                self.send(404, {"message": "Not Found"})

            def do_GET(self):
                auth = self.headers.get("Authorization")
                fake.requests.append(("GET", self.path, auth))
                if self.path == "/market/v1/stats":
                    return self.send(200, {"schemaVersion": 1, "plugins": fake.market})
                parts = self.path.split("/")
                # /api/repos/{owner}/{repo}/...
                if len(parts) < 6 or parts[1] != "api" or parts[2] != "repos":
                    return self.send(404, {"message": "Not Found"})
                name = parts[3] + "/" + parts[4]
                repo = fake.repos.get(name)
                rest = "/".join(parts[5:])
                if repo is None:
                    return self.send(404, {"message": "Not Found"})
                if rest == "contents/manifest.json":
                    if repo.get("manifest") is None:
                        return self.send(404, {"message": "Not Found"})
                    content = base64.b64encode(json.dumps(repo["manifest"]).encode()).decode()
                    # GitHub wraps base64 at 60 columns.
                    wrapped = "\n".join(content[i:i + 60] for i in range(0, len(content), 60))
                    return self.send(200, {"encoding": "base64", "content": wrapped})
                if rest in ("traffic/clones", "traffic/views"):
                    if auth is None:
                        return self.send(401, {"message": "Requires authentication"})
                    if auth.removeprefix("Bearer ") not in fake.valid_tokens:
                        return self.send(401, {"message": "Bad credentials"})
                    if not repo.get("access", True):
                        return self.send(403, {"message": "Resource not accessible by integration"})
                    kind = rest.split("/")[1]
                    return self.send(200, repo.get(kind + "_raw") or day_series(kind, repo.get(kind, {})))
                self.send(404, {"message": "Not Found"})

        return Handler
