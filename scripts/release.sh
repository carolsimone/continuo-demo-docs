#!/usr/bin/env bash
#
# release.sh — drive a continuo blue/green release from CD.
#
# The calling workflow only builds and pushes the service image. dbt compile and
# manifest upload happen inside continuo. This script talks to continuo's public
# release API (`/api/v1` on the ui, reached at CONTINUO_URL) over HTTPS with a
# bearer token, and:
#   1. reads GET /api/v1/current-prod — if current_prod is unseeded, this run is
#      a bootstrap (promote without validation);
#   2. POSTs the release to /api/v1/releases (continuo replies 202 Accepted
#      immediately);
#   3. polls GET /api/v1/releases/<id> to a terminal status, failing on
#      `rejected` and `superseded`.
#
# The API is documented in continuo's deploy/README.md, section "Releasing from
# CI (GitHub Actions)".
#
# continuo models a release as a SINGLE changed service: POST /releases takes
# one {service, image_tag} and continuo reconstructs the full manifest set from
# the live service_prod pointers. continuo runs dbt compile internally to
# produce the manifest; the caller never touches S3 for a dbt release. The
# canonical key <service>/<release_id>/manifest.json is derived by continuo — so
# it is not sent in the body.
#
# Authentication. Every call carries `Authorization: Bearer <token>`:
#   - CONTINUO_TOKEN set: that token is used as is. This is an operator's own
#     OIDC ID token, for running a release from a workstation (continuo's
#     deploy/AUTH.md, "Bearer tokens", shows how to get one from Dex).
#   - otherwise: the GitHub Actions OIDC token of the running workflow, requested
#     afresh for each API call (these tokens expire within minutes), with the
#     origin of CONTINUO_URL as its audience. The job must grant
#     `permissions: id-token: write`, and the repository must be bound to the
#     service in continuo's `ciAuth.bindings`.
# The token is never printed.
#
# A CI token carries the repository and commit, so REPO and COMMIT_SHA must be
# equal to the token's or be left unset. An operator token must send both. A CI
# bootstrap is refused (403 bootstrap_not_allowed) unless the repository's
# binding sets `allowBootstrap: true`; bootstrapping a service is an operator
# action.
#
# Required environment:
#   CONTINUO_URL     — origin of continuo's ui, e.g. https://continuo.example.com
#                      (scheme://host[:port], no path)
#   RELEASE_ID       — unique per run, e.g. rel-<shortsha>-<runid>; letters,
#                      digits, '.', '_' and '-', starting with a letter or digit,
#                      at most 128 characters
#   SERVICE          — the single changed service, e.g. service-3
#   IMAGE_TAG        — that service's image tag: a dbt release passes the bare
#                      short sha (continuo composes the pull ref itself); a
#                      python release (KIND=python) passes the full pullable
#                      registry ref, since continuo runs that verbatim.
#
# Optional:
#   CONTINUO_TOKEN   — bearer token to use instead of the GitHub Actions OIDC
#                      token (see Authentication).
#   KIND             — "python" to mark this release as a python-node service
#                      (adds "kind":"python" to the POST body). Any other
#                      value, or leaving it unset, keeps the dbt behavior: no
#                      "kind" field at all.
#   REPO             — "<owner>/<repo>" sent as "repo" (see Authentication).
#   COMMIT_SHA       — full commit sha sent as "commit_sha".
#   FORCE_BOOTSTRAP  — "true" to promote without validation regardless of
#                      current_prod state, re-baselining every node's stored
#                      content hash (used after continuo changes its hash
#                      formula). Default: bootstrap only when prod is unseeded.
#   POLL_ATTEMPTS    — terminal-status poll attempts (default 135). With the
#                      default interval that is ~9 minutes, just under the
#                      workflow job's cap, so a stuck release exits with a clean
#                      message rather than a hard job kill.
#   POLL_INTERVAL    — seconds between poll attempts (default 4)
#   RETRY_DELAY      — seconds before the first retry of a transient API
#                      failure; each further retry waits one more multiple of it
#                      (default 2)
#
# Exit status: 0 when the release is promoted; 1 on a rejected or superseded
# release, an API error, or a poll timeout.

set -euo pipefail

: "${CONTINUO_URL:?CONTINUO_URL must be set}"
: "${RELEASE_ID:?RELEASE_ID must be set}"
: "${SERVICE:?SERVICE must be set}"
: "${IMAGE_TAG:?IMAGE_TAG must be set}"
CONTINUO_TOKEN="${CONTINUO_TOKEN:-}"
KIND="${KIND:-}"
REPO="${REPO:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
FORCE_BOOTSTRAP="${FORCE_BOOTSTRAP:-false}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-135}"
POLL_INTERVAL="${POLL_INTERVAL:-4}"
RETRY_DELAY="${RETRY_DELAY:-2}"
API_TRIES=4

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required but not installed" >&2; exit 1; }
done

case "$CONTINUO_URL" in
  http://* | https://*) ;;
  *) echo "ERROR: CONTINUO_URL must start with http:// or https:// (got '${CONTINUO_URL}')" >&2; exit 1 ;;
esac
BASE_URL="${CONTINUO_URL%/}"
# The OIDC audience is the origin of CONTINUO_URL: scheme://host[:port], no path.
AUDIENCE="$(printf '%s' "$BASE_URL" | sed -E 's|^(https?://[^/?#]+).*|\1|')"

if ! printf '%s' "$RELEASE_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
  echo "ERROR: RELEASE_ID '${RELEASE_ID}' must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\$" >&2
  exit 1
fi

if [ -z "$CONTINUO_TOKEN" ] \
   && { [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; }; then
  echo "ERROR: no bearer token available. Set CONTINUO_TOKEN (an operator's token), or run in a GitHub Actions job with 'permissions: id-token: write'." >&2
  exit 1
fi

RESP_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE"' EXIT

# get_token
#
# Prints the bearer token: CONTINUO_TOKEN when set, otherwise a fresh GitHub
# Actions OIDC token for AUDIENCE. The Actions request token travels in a header
# read from stdin so it never appears in a process listing.
get_token() {
  if [ -n "$CONTINUO_TOKEN" ]; then
    printf '%s' "$CONTINUO_TOKEN"
    return
  fi
  local audience_enc value
  audience_enc="$(jq -rn --arg a "$AUDIENCE" '$a | @uri')"
  value="$(printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    | curl -sS --fail -H @- "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience_enc}" \
    | jq -r '.value // empty')" || {
    echo "ERROR: could not request a GitHub Actions OIDC token (does the job grant 'permissions: id-token: write'?)" >&2
    return 1
  }
  if [ -z "$value" ]; then
    echo "ERROR: the GitHub Actions OIDC token endpoint returned no token" >&2
    return 1
  fi
  printf '%s' "$value"
}

# api METHOD PATH [BODY]
#
# One authenticated call to continuo. Sets HTTP_STATUS (the HTTP status code, or
# 000 when curl itself failed) and HTTP_BODY (the response body), and always
# returns 0 so the caller decides what each status means. Transient failures —
# a curl network error, 429, 502, 503, 504 — are retried API_TRIES times in all
# with a short, growing backoff; every other status is returned straight away.
# The bearer token goes to curl on stdin (-H @-), keeping it out of the process
# listing.
HTTP_STATUS=""
HTTP_BODY=""
api() {
  local method="$1" path="$2" body="${3:-}" attempt=1 rc token
  local -a args
  while :; do
    token="$(get_token)"
    : >"$RESP_FILE"
    args=(-sS -X "$method" -o "$RESP_FILE" -w '%{http_code}' -H @- -H 'Accept: application/json')
    if [ -n "$body" ]; then
      args+=(-H 'Content-Type: application/json' -d "$body")
    fi
    rc=0
    HTTP_STATUS="$(printf 'Authorization: Bearer %s\n' "$token" | curl "${args[@]}" "${BASE_URL}${path}")" || rc=$?
    [ "$rc" -eq 0 ] || HTTP_STATUS="000"
    HTTP_BODY="$(cat "$RESP_FILE")"
    case "$HTTP_STATUS" in
      000 | 429 | 502 | 503 | 504)
        if [ "$attempt" -lt "$API_TRIES" ]; then
          echo "transient failure on ${method} ${path} (HTTP ${HTTP_STATUS}); retrying (${attempt}/$((API_TRIES - 1)))" >&2
          sleep $((RETRY_DELAY * attempt))
          attempt=$((attempt + 1))
          continue
        fi
        ;;
    esac
    return 0
  done
}

# api_fail WHAT
#
# Reports a failed call from HTTP_STATUS/HTTP_BODY: the status, plus the `code`
# and `error` fields of continuo's {error, code} answer.
api_fail() {
  local what="$1" code error
  code="$(jq -r '.code // empty' <<<"$HTTP_BODY" 2>/dev/null || true)"
  error="$(jq -r '.error // empty' <<<"$HTTP_BODY" 2>/dev/null || true)"
  if [ "$HTTP_STATUS" = "000" ]; then
    echo "ERROR: ${what} failed: could not reach ${BASE_URL}" >&2
  else
    echo "ERROR: ${what} failed: HTTP ${HTTP_STATUS} code=${code:-unknown} error=${error:-none}" >&2
  fi
  if [ "$HTTP_STATUS" = "403" ] && [ "$code" = "bootstrap_not_allowed" ]; then
    echo "Bootstrapping this service needs an operator token (CONTINUO_TOKEN) or a ciAuth binding with allowBootstrap: true." >&2
  fi
}

echo "Driving release ${RELEASE_ID} (service=${SERVICE}, kind=${KIND:-dbt}, image_tag=${IMAGE_TAG}) against ${BASE_URL}"

# Bootstrap decision, two paths:
#   - unseeded prod: GET /api/v1/current-prod returns current_prod_release_id=""
#     when production has never been seeded — the first release must bootstrap
#     (promote without validation), since a normal release would be rejected
#     because every cross-service upstream looks new against empty prod;
#   - FORCE_BOOTSTRAP=true: deliberate re-baseline of a seeded prod, needed
#     when continuo changes its content-hash formula and every stored hash
#     mismatches — a normal release would treat the whole estate as changed
#     and validate the entire topology.
# A failed read stops the run: guessing "unseeded" would turn it into a
# bootstrap that skips validation.
api GET /api/v1/current-prod
if [ "$HTTP_STATUS" != "200" ]; then
  api_fail "GET /api/v1/current-prod"
  exit 1
fi
CUR_ID="$(jq -r '.current_prod_release_id // empty' <<<"$HTTP_BODY")"
if [ "$FORCE_BOOTSTRAP" = "true" ] || [ -z "$CUR_ID" ]; then BOOTSTRAP=true; else BOOTSTRAP=false; fi
echo "current_prod release_id='${CUR_ID}' force_bootstrap=${FORCE_BOOTSTRAP} -> bootstrap=${BOOTSTRAP}"

BODY="$(jq -n \
  --arg release_id "$RELEASE_ID" \
  --arg service "$SERVICE" \
  --arg image_tag "$IMAGE_TAG" \
  --argjson bootstrap "$BOOTSTRAP" \
  --arg kind "$KIND" \
  --arg repo "$REPO" \
  --arg commit_sha "$COMMIT_SHA" \
  '{release_id: $release_id, service: $service, image_tag: $image_tag, bootstrap: $bootstrap}
   + (if $kind == "python" then {kind: "python"} else {} end)
   + (if $repo != "" then {repo: $repo} else {} end)
   + (if $commit_sha != "" then {commit_sha: $commit_sha} else {} end)')"
echo "POST /api/v1/releases ${BODY}"
api POST /api/v1/releases "$BODY"
if [ "$HTTP_STATUS" != "202" ]; then
  api_fail "POST /api/v1/releases"
  exit 1
fi

# Poll to a terminal status: promoted succeeds; rejected and superseded fail. A
# poll that still fails transiently after its retries is skipped and tried again
# on the next attempt; any other error ends the run.
STATUS=""
LAST_STATUS=""
for _ in $(seq 1 "$POLL_ATTEMPTS"); do
  api GET "/api/v1/releases/${RELEASE_ID}"
  case "$HTTP_STATUS" in
    200) ;;
    000 | 429 | 502 | 503 | 504)
      echo "poll skipped: continuo unavailable (HTTP ${HTTP_STATUS})" >&2
      sleep "$POLL_INTERVAL"
      continue
      ;;
    *)
      api_fail "GET /api/v1/releases/${RELEASE_ID}"
      exit 1
      ;;
  esac
  STATUS="$(jq -r '.status // empty' <<<"$HTTP_BODY")"
  if [ "$STATUS" != "$LAST_STATUS" ]; then
    echo "release ${RELEASE_ID} status: ${STATUS:-unknown}"
    LAST_STATUS="$STATUS"
  fi
  if [ "$(jq -r '.terminal // false' <<<"$HTTP_BODY")" = "true" ]; then
    UI_URL="$(jq -r '.ui_url // empty' <<<"$HTTP_BODY")"
    case "$STATUS" in
      promoted)
        echo "release ${RELEASE_ID} promoted"
        [ -z "$UI_URL" ] || echo "details: ${UI_URL}"
        exit 0
        ;;
      rejected)
        echo "release ${RELEASE_ID} rejected" >&2
        echo "reject_reason: $(jq -r '.reject_reason // empty' <<<"$HTTP_BODY")" >&2
        echo "reject_detail: $(jq -r '.reject_detail // empty' <<<"$HTTP_BODY")" >&2
        [ -z "$UI_URL" ] || echo "details: ${UI_URL}" >&2
        exit 1
        ;;
      superseded)
        echo "release ${RELEASE_ID} superseded by a newer release before it could be promoted" >&2
        [ -z "$UI_URL" ] || echo "details: ${UI_URL}" >&2
        exit 1
        ;;
      *)
        echo "release ${RELEASE_ID} ended with unexpected terminal status '${STATUS}'" >&2
        exit 1
        ;;
    esac
  fi
  sleep "$POLL_INTERVAL"
done
echo "timeout waiting for terminal status (last: ${STATUS:-unknown})" >&2
exit 1
