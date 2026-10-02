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
import socket
import subprocess
import threading
import time
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


# A stub answer is (http_status, body) or (http_status, body, extra_headers). A
# body that is a str is sent as is (a non-JSON error page); anything else as
# JSON. The sentinel _STALL makes the stub hold the request without answering.
_STALL = (0, None)


def _sequence(answer):
    """A list is consumed in order, the last answer repeating; a tuple repeats."""
    return list(answer) if isinstance(answer, list) else [answer]


class _Stub:
    """A scripted continuo ui."""

    def __init__(self, current_prod=None, post=None, polls=None, oidc=None, path_prefix=""):
        self.current_prod = _sequence(current_prod or (200, {"current_prod_release_id": "rel-0"}))
        self.post = _sequence(post or (202, {"release_id": "rel-1", "status": "received"}))
        self.polls = _sequence(polls or (200, _PROMOTED))
        self.oidc = _sequence(oidc or (200, None))
        self.path_prefix = path_prefix
        self.requests = []  # (method, path, headers, body); path without path_prefix
        self.oidc_calls = []  # (query, headers)
        self._lock = threading.Lock()
        self._release = threading.Event()
        stub = self

        def take(answers):
            return answers[0] if len(answers) == 1 else answers.pop(0)

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _reply(self, status, body, headers=None):
                if (status, body) == _STALL:
                    stub._release.wait(60)
                    return
                data = (body if isinstance(body, str) else json.dumps(body)).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                for name, value in (headers or {}).items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                url = urllib.parse.urlparse(self.path)
                if url.path == "/oidc":
                    with stub._lock:
                        stub.oidc_calls.append((url.query, dict(self.headers)))
                        n = len(stub.oidc_calls)
                        status, body, *rest = take(stub.oidc)
                    if body is None:
                        body = {"value": f"oidc-token-{n}"}
                    return self._reply(status, body, *rest)
                path = self.path.removeprefix(stub.path_prefix)
                with stub._lock:
                    stub.requests.append(("GET", path, dict(self.headers), None))
                    if path == "/api/v1/current-prod":
                        answer = take(stub.current_prod)
                    else:
                        answer = take(stub.polls)
                return self._reply(*answer)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode()
                with stub._lock:
                    stub.requests.append(
                        ("POST", self.path.removeprefix(stub.path_prefix), dict(self.headers), body)
                    )
                    answer = take(stub.post)
                self._reply(*answer)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def __enter__(self):
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._release.set()
        self._server.shutdown()
        self._server.server_close()

    def posts(self):
        return [r for r in self.requests if r[0] == "POST"]


def _run_release(stub, extra_env=None, drop_env=()):
    return _run_release_at(stub.url, extra_env, drop_env)


def _run_release_at(url, extra_env=None, drop_env=()):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACTIONS_", "CONTINUO_"))}
    env.update(
        CONTINUO_URL=url,
        CONTINUO_TOKEN="test",
        RELEASE_ID="rel-1",
        SERVICE="svc",
        IMAGE_TAG="abc1234",
        POLL_INTERVAL="0",
        RETRY_DELAY="0",
        RATE_LIMIT_DELAY="0",
    )
    env.update(extra_env or {})
    for key in drop_env:
        env.pop(key, None)
    return subprocess.run(
        ["bash", str(_SCRIPT)], env=env, capture_output=True, text=True, timeout=60
    )


class ReleaseShTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("curl") and shutil.which("jq"):
            return
        # A CI run must not silently skip the suite for lack of a tool.
        if os.environ.get("CI") == "true":
            raise AssertionError("curl and jq are required in CI")
        raise unittest.SkipTest("curl and jq are required")

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

    def test_transient_503_on_current_prod_is_retried(self):
        unavailable = (503, {"error": "upstream down", "code": "upstream_unavailable"})
        with _Stub(
            current_prod=[unavailable, (200, {"current_prod_release_id": "rel-0"})]
        ) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse(json.loads(stub.posts()[0][3])["bootstrap"])

    def test_transient_503_on_post_is_retried(self):
        unavailable = (503, {"error": "upstream down", "code": "upstream_unavailable"})
        with _Stub(post=[unavailable, (202, {"release_id": "rel-1", "status": "received"})]) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(len(stub.posts()), 2)

    def test_retries_run_out_on_a_persistent_503(self):
        unavailable = (503, {"error": "upstream down", "code": "upstream_unavailable"})
        with _Stub(current_prod=unavailable) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("upstream_unavailable", result.stderr)
        self.assertEqual(len([r for r in stub.requests if r[1] == "/api/v1/current-prod"]), 4)
        self.assertEqual(stub.posts(), [])

    def test_retries_run_out_when_continuo_is_unreachable(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]  # closed again on leaving the block
        result = _run_release_at(f"http://127.0.0.1:{port}")

        self.assertEqual(result.returncode, 1)
        self.assertIn("could not reach", result.stderr)
        self.assertEqual(result.stderr.count("retrying"), 3)

    def test_non_transient_curl_error_is_not_retried(self):
        result = _run_release_at("http://[bad")

        self.assertEqual(result.returncode, 1)
        self.assertIn("malformed URL", result.stderr)
        self.assertIn("not retried", result.stderr)
        self.assertNotIn("retrying", result.stderr)

    def test_429_honours_retry_after(self):
        limited = (429, {"error": "slow down", "code": "rate_limited"}, {"Retry-After": "1"})
        with _Stub(current_prod=[limited, (200, {"current_prod_release_id": "rel-0"})]) as stub:
            started = time.monotonic()
            result = _run_release(stub)
            elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("retrying in 1s", result.stderr)
        self.assertGreaterEqual(elapsed, 1)

    def test_429_without_retry_after_waits_the_rate_limit_delay(self):
        limited = (429, {"error": "slow down", "code": "rate_limited"})
        with _Stub(current_prod=[limited, (200, {"current_prod_release_id": "rel-0"})]) as stub:
            result = _run_release(stub, {"RATE_LIMIT_DELAY": "1"})

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("retrying in 1s", result.stderr)

    def test_an_oversized_retry_after_is_capped_without_shell_errors(self):
        limited = (429, {"error": "slow down", "code": "rate_limited"}, {"Retry-After": "9" * 30})
        with _Stub(current_prod=[limited, (200, {"current_prod_release_id": "rel-0"})]) as stub:
            result = _run_release(stub, {"POLL_TIMEOUT_SECONDS": "5"})

        # The capped 60s wait does not fit the 5s budget, so the read fails.
        self.assertEqual(result.returncode, 1)
        self.assertIn("rate_limited", result.stderr + result.stdout)
        self.assertNotIn("integer expression expected", result.stderr)
        self.assertEqual(len(stub.requests), 1)

    def test_zero_padded_timing_values_are_read_as_decimal(self):
        with _Stub() as stub:
            result = _run_release(
                stub,
                {
                    "POLL_TIMEOUT_SECONDS": "0900",
                    "POLL_INTERVAL": "00",
                    "RETRY_DELAY": "00",
                    "RATE_LIMIT_DELAY": "08",
                },
            )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("value too great for base", result.stderr)

    def test_an_overlong_timing_value_is_refused_locally(self):
        with _Stub() as stub:
            result = _run_release(stub, {"POLL_TIMEOUT_SECONDS": "1234567"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("POLL_TIMEOUT_SECONDS", result.stderr)
        self.assertEqual(stub.requests, [])

    def test_a_stalled_connection_gives_up_within_the_budget(self):
        # A server that accepts the connection and never answers.
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(8)
        held = []

        def accept_and_hold():
            try:
                while True:
                    held.append(server.accept()[0])
            except OSError:  # the listening socket was closed
                pass

        threading.Thread(target=accept_and_hold, daemon=True).start()
        try:
            started = time.monotonic()
            result = _run_release_at(
                f"http://127.0.0.1:{server.getsockname()[1]}", {"POLL_TIMEOUT_SECONDS": "3"}
            )
            elapsed = time.monotonic() - started
        finally:
            server.close()
            for conn in held:
                conn.close()

        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out", result.stderr)
        self.assertLess(elapsed, 15)

    def test_a_stalled_poll_ends_in_the_poll_timeout(self):
        with _Stub(polls=_STALL) as stub:
            started = time.monotonic()
            result = _run_release(stub, {"POLL_TIMEOUT_SECONDS": "3", "POLL_INTERVAL": "1"})
            elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 1)
        self.assertIn("poll skipped", result.stderr)
        self.assertIn("timeout waiting for terminal status", result.stderr)
        self.assertLess(elapsed, 15)

    def test_non_json_error_body_is_shown(self):
        page = "<html><body>" + "bad gateway " * 40 + "</body></html>"
        with _Stub(post=(400, page)) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 400", result.stderr)
        self.assertIn("<html><body>bad gateway", result.stderr)
        # Only the first 200 characters.
        self.assertNotIn("</body>", result.stderr)

    def test_not_found_on_a_poll_fails_fast(self):
        missing = (404, {"error": "no such release", "code": "not_found"})
        with _Stub(polls=[missing]) as stub:
            result = _run_release(stub)

        self.assertEqual(result.returncode, 1)
        self.assertIn("not_found", result.stderr)

    def test_poll_timeout_fails(self):
        pending = (200, {"release_id": "rel-1", "status": "validating", "terminal": False})
        with _Stub(polls=pending) as stub:
            started = time.monotonic()
            result = _run_release(stub, {"POLL_TIMEOUT_SECONDS": "2", "POLL_INTERVAL": "1"})
            elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 1)
        self.assertIn("timeout waiting for terminal status (last: validating)", result.stderr)
        self.assertLess(elapsed, 10)

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

    def test_audience_is_the_origin_of_a_url_with_a_path(self):
        with _Stub(path_prefix="/continuo") as stub:
            result = _run_release(
                stub,
                {
                    "CONTINUO_URL": stub.url + "/continuo/",
                    "ACTIONS_ID_TOKEN_REQUEST_URL": stub.url + "/oidc?api-version=2.0",
                    "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "request-secret",
                },
                drop_env=("CONTINUO_TOKEN",),
            )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        for query, _ in stub.oidc_calls:
            self.assertEqual(urllib.parse.parse_qs(query)["audience"], [stub.url])
        self.assertEqual(stub.requests[0][1], "/api/v1/current-prod")

    def _oidc_env(self, stub):
        return {
            "ACTIONS_ID_TOKEN_REQUEST_URL": stub.url + "/oidc?api-version=2.0",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "request-secret",
        }

    def test_transient_oidc_failure_is_retried(self):
        with _Stub(oidc=[(500, {"message": "oops"}), (200, None)]) as stub:
            result = _run_release(stub, self._oidc_env(stub), drop_env=("CONTINUO_TOKEN",))

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("OIDC token", result.stderr)
        self.assertIn("promoted", result.stdout)

    def test_oidc_429_honours_retry_after(self):
        limited = (429, {"message": "slow down"}, {"Retry-After": "1"})
        with _Stub(oidc=[limited, (200, None)]) as stub:
            started = time.monotonic()
            result = _run_release(stub, self._oidc_env(stub), drop_env=("CONTINUO_TOKEN",))
            elapsed = time.monotonic() - started

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("retrying in 1s", result.stderr)
        self.assertGreaterEqual(elapsed, 1)

    def test_oidc_failure_mid_poll_counts_as_a_failed_poll(self):
        pending = (200, {"release_id": "rel-1", "status": "validating", "terminal": False})
        # Calls 1-2 (current-prod, POST) and the first poll succeed; the token
        # requests for the next poll fail through all their retries.
        oidc = [(200, None)] * 3 + [(503, {"message": "down"})] * 4 + [(200, None)]
        with _Stub(polls=[pending, (200, _PROMOTED)], oidc=oidc) as stub:
            result = _run_release(stub, self._oidc_env(stub), drop_env=("CONTINUO_TOKEN",))

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("poll skipped", result.stderr)

    def test_forbidden_oidc_request_fails_fast(self):
        with _Stub(oidc=(403, {"message": "forbidden"})) as stub:
            result = _run_release(stub, self._oidc_env(stub), drop_env=("CONTINUO_TOKEN",))

        self.assertEqual(result.returncode, 1)
        self.assertIn("OIDC token", result.stderr)
        self.assertIn("id-token: write", result.stderr)
        self.assertEqual(len(stub.oidc_calls), 1)
        self.assertEqual(stub.requests, [])

    def test_oidc_answer_without_a_token_fails(self):
        with _Stub(oidc=(200, {"value": ""})) as stub:
            result = _run_release(stub, self._oidc_env(stub), drop_env=("CONTINUO_TOKEN",))

        self.assertEqual(result.returncode, 1)
        self.assertIn("returned no token", result.stderr)

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
        bad_ids = ["-bad id", "rel-1\nrel-2", "rel-1\n", "x" * 129, ""]
        for bad_id in bad_ids:
            with self.subTest(release_id=bad_id), _Stub() as stub:
                result = _run_release(stub, {"RELEASE_ID": bad_id})

                self.assertEqual(result.returncode, 1)
                self.assertIn("RELEASE_ID", result.stderr)
                self.assertEqual(stub.requests, [])

    def test_a_release_id_at_the_length_limit_is_accepted(self):
        with _Stub() as stub:
            result = _run_release(stub, {"RELEASE_ID": "a" + "b" * 127})

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
