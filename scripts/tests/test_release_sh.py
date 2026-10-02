"""Tests for scripts/release.sh against a stub of continuo's public release API.

The stub is a real HTTP server on a loopback port; release.sh runs as a
subprocess with an operator token (CONTINUO_TOKEN) and polls it like it would
poll continuo. Each scenario scripts the stub's answers and asserts on the exit
status, the output, and the requests the script made.
"""

import http.server
import json
import os
import pathlib
import shutil
import subprocess
import threading
import unittest
import urllib.parse

_SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "release.sh"

_PROMOTED = {
    "release_id": "rel-1",
    "service": "svc",
    "status": "promoted",
    "terminal": True,
    "ui_url": "https://continuo.example.com/releases/rel-1",
}


class _Stub:
    """A scripted continuo ui. Answers are (http_status, json_body) pairs."""

    def __init__(self, current_prod=None, post=None, polls=None):
        self.current_prod = current_prod or (200, {"current_prod_release_id": "rel-0"})
        self.post = post or (202, {"release_id": "rel-1", "status": "received"})
        # Consumed in order; the last answer repeats.
        self.polls = list(polls or [(200, _PROMOTED)])
        self.requests = []  # (method, path, headers, body)
        self.oidc_calls = []  # (query, headers)
        self._lock = threading.Lock()
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _reply(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                if url.path == "/oidc":
                    with stub._lock:
                        stub.oidc_calls.append((url.query, dict(self.headers)))
                        n = len(stub.oidc_calls)
                    return self._reply(200, {"value": f"oidc-token-{n}"})
                with stub._lock:
                    stub.requests.append(("GET", self.path, dict(self.headers), None))
                    if self.path == "/api/v1/current-prod":
                        return self._reply(*stub.current_prod)
                    answer = stub.polls[0] if len(stub.polls) == 1 else stub.polls.pop(0)
                return self._reply(*answer)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode()
                with stub._lock:
                    stub.requests.append(("POST", self.path, dict(self.headers), body))
                self._reply(*stub.post)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._server.shutdown()
        self._server.server_close()

    def posts(self):
        return [r for r in self.requests if r[0] == "POST"]


def _run_release(stub, extra_env=None, drop_env=()):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACTIONS_", "CONTINUO_"))}
    env.update(
        CONTINUO_URL=stub.url,
        CONTINUO_TOKEN="test",
        RELEASE_ID="rel-1",
        SERVICE="svc",
        IMAGE_TAG="abc1234",
        POLL_INTERVAL="0",
        RETRY_DELAY="0",
    )
    env.update(extra_env or {})
    for key in drop_env:
        env.pop(key, None)
    return subprocess.run(
        ["bash", str(_SCRIPT)], env=env, capture_output=True, text=True, timeout=60
    )


@unittest.skipUnless(shutil.which("curl") and shutil.which("jq"), "curl and jq are required")
class ReleaseShTest(unittest.TestCase):
    def test_normal_release_is_promoted(self):
        validating = (200, {"release_id": "rel-1", "status": "validating", "terminal": False})
        with _Stub(polls=[validating, (200, _PROMOTED)]) as stub:
            result = _run_release(
                stub, {"REPO": "carolsimone/continuo-demo", "COMMIT_SHA": "0123456789abcdef"}
            )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("promoted", result.stdout)
        self.assertIn(_PROMOTED["ui_url"], result.stdout)

        posts = stub.posts()
        self.assertEqual(len(posts), 1)
        _, path, headers, body = posts[0]
        self.assertEqual(path, "/api/v1/releases")
        self.assertEqual(
            json.loads(body),
            {
                "release_id": "rel-1",
                "service": "svc",
                "image_tag": "abc1234",
                "bootstrap": False,
                "repo": "carolsimone/continuo-demo",
                "commit_sha": "0123456789abcdef",
            },
        )
        for _, _, request_headers, _ in stub.requests:
            self.assertEqual(request_headers["Authorization"], "Bearer test")
        polls = [r for r in stub.requests if r[1] == "/api/v1/releases/rel-1"]
        self.assertEqual(len(polls), 2)

    def test_repo_and_commit_sha_are_omitted_when_unset(self):
        with _Stub() as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        body = json.loads(stub.posts()[0][3])
        self.assertNotIn("repo", body)
        self.assertNotIn("commit_sha", body)
        self.assertNotIn("kind", body)

    def test_python_kind_adds_kind_to_the_body(self):
        with _Stub() as stub:
            result = _run_release(stub, {"KIND": "python"})

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(stub.posts()[0][3])["kind"], "python")

    def test_unseeded_prod_bootstraps(self):
        with _Stub(current_prod=(200, {"current_prod_release_id": ""})) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue(json.loads(stub.posts()[0][3])["bootstrap"])

    def test_force_bootstrap_bootstraps_a_seeded_prod(self):
        with _Stub() as stub:
            result = _run_release(stub, {"FORCE_BOOTSTRAP": "true"})

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue(json.loads(stub.posts()[0][3])["bootstrap"])

    def test_failed_current_prod_read_does_not_bootstrap(self):
        error = {"error": "token rejected", "code": "invalid_token"}
        with _Stub(current_prod=(401, error)) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid_token", result.stderr)
        self.assertEqual(stub.posts(), [])

    def test_rejected_release_fails_with_the_reason(self):
        rejected = {
            "release_id": "rel-1",
            "status": "rejected",
            "terminal": True,
            "reject_reason": "validation_failed",
            "reject_detail": "ltv_per_user reads a column that no longer exists",
            "ui_url": "https://continuo.example.com/releases/rel-1",
        }
        with _Stub(polls=[(200, rejected)]) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        output = result.stdout + result.stderr
        self.assertIn("validation_failed", output)
        self.assertIn("ltv_per_user reads a column that no longer exists", output)
        self.assertIn(rejected["ui_url"], output)

    def test_superseded_release_fails(self):
        superseded = {"release_id": "rel-1", "status": "superseded", "terminal": True}
        with _Stub(polls=[(200, superseded)]) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("superseded", result.stdout + result.stderr)

    def test_bootstrap_not_allowed_explains_the_operator_action(self):
        refused = {"error": "bootstrap is not permitted", "code": "bootstrap_not_allowed"}
        with _Stub(
            current_prod=(200, {"current_prod_release_id": ""}), post=(403, refused)
        ) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("bootstrap_not_allowed", result.stderr)
        self.assertIn("operator token (CONTINUO_TOKEN)", result.stderr)
        self.assertIn("allowBootstrap: true", result.stderr)
        self.assertEqual(len(stub.posts()), 1)

    def test_conflict_fails_fast_without_polling(self):
        conflict = {"error": "release_id reused with a different body", "code": "release_kind_conflict"}
        with _Stub(post=(409, conflict)) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("release_kind_conflict", result.stderr)
        self.assertIn("release_id reused with a different body", result.stderr)
        self.assertEqual(len(stub.posts()), 1)
        self.assertFalse([r for r in stub.requests if r[1].startswith("/api/v1/releases/")])

    def test_transient_503_on_a_poll_is_retried(self):
        unavailable = (503, {"error": "upstream down", "code": "upstream_unavailable"})
        with _Stub(polls=[unavailable, (200, _PROMOTED)]) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("promoted", result.stdout)
        self.assertIn("transient failure", result.stderr)
        self.assertEqual(len(stub.posts()), 1)

    def test_not_found_on_a_poll_fails_fast(self):
        missing = (404, {"error": "no such release", "code": "not_found"})
        with _Stub(polls=[missing]) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("not_found", result.stderr)

    def test_poll_timeout_fails(self):
        pending = (200, {"release_id": "rel-1", "status": "validating", "terminal": False})
        with _Stub(polls=[pending]) as stub:
            result = _run_release(stub, {"POLL_ATTEMPTS": "3"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("timeout", result.stderr)

    def test_github_actions_token_is_requested_afresh_for_each_call(self):
        with _Stub() as stub:
            result = _run_release(
                stub,
                {
                    "CONTINUO_URL": stub.url + "/",
                    "ACTIONS_ID_TOKEN_REQUEST_URL": stub.url + "/oidc?api-version=2.0",
                    "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "request-secret",
                },
                drop_env=("CONTINUO_TOKEN",),
            )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        # current-prod, POST and one poll: one token each.
        self.assertEqual(len(stub.oidc_calls), 3)
        for query, headers in stub.oidc_calls:
            params = urllib.parse.parse_qs(query)
            self.assertEqual(params["audience"], [stub.url])
            self.assertEqual(headers["Authorization"], "bearer request-secret")
        self.assertEqual(
            [r[2]["Authorization"] for r in stub.requests],
            ["Bearer oidc-token-1", "Bearer oidc-token-2", "Bearer oidc-token-3"],
        )
        self.assertNotIn("oidc-token", result.stdout + result.stderr)
        self.assertNotIn("request-secret", result.stdout + result.stderr)

    def test_no_token_source_fails_before_any_request(self):
        with _Stub() as stub:
            result = _run_release(stub, drop_env=("CONTINUO_TOKEN",))

        self.assertEqual(result.returncode, 1)
        self.assertIn("CONTINUO_TOKEN", result.stderr)
        self.assertEqual(stub.requests, [])

    def test_token_is_never_printed(self):
        with _Stub(post=(403, {"error": "no", "code": "forbidden"})) as stub:
            result = _run_release(stub, {"CONTINUO_TOKEN": "super-secret-token"})

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("super-secret-token", result.stdout + result.stderr)

    def test_invalid_release_id_is_refused_locally(self):
        with _Stub() as stub:
            result = _run_release(stub, {"RELEASE_ID": "-bad id"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("RELEASE_ID", result.stderr)
        self.assertEqual(stub.requests, [])


if __name__ == "__main__":
    unittest.main()
