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
#   POLL_TIMEOUT_SECONDS — wall-clock budget, in seconds, for the whole run from
#                      the first API call: every call, retry and sleep stays
#                      inside it, and the script exits 1 with "timeout waiting
#                      for terminal status" once it is spent (default 900). Keep
#                      the calling job's own time limit comfortably above the
#                      image build plus this budget.
#   POLL_INTERVAL    — seconds between poll attempts (default 4)
#   RETRY_DELAY      — seconds before the first retry of a transient API
#                      failure; each further retry waits one more multiple of it
#                      (default 2)
#   RATE_LIMIT_DELAY — seconds to wait before retrying a 429 when the answer
#                      carries no Retry-After header (default 20)
#
# Every HTTP request has a 10 s connect timeout and a 30 s total timeout (less
# when the budget has less left), so a stalled connection fails the attempt
# instead of hanging the run. Transient failures are retried up to 4 tries per
# call: connection-level curl errors (6, 7, 28, 35, 52, 55, 56), a failed OIDC
# token request, and HTTP 429, 502, 503 and 504. Any other curl error, and any
# other HTTP status, ends the run at once.
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
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-900}"
POLL_INTERVAL="${POLL_INTERVAL:-4}"
RETRY_DELAY="${RETRY_DELAY:-2}"
RATE_LIMIT_DELAY="${RATE_LIMIT_DELAY:-20}"
API_TRIES=4
CONNECT_TIMEOUT=10
MAX_TIME=30

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

for var in POLL_TIMEOUT_SECONDS POLL_INTERVAL RETRY_DELAY RATE_LIMIT_DELAY; do
  if ! [[ ${!var} =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${var} must be a whole number of seconds (got '${!var}')" >&2
    exit 1
  fi
done

# A whole-string match: a value with a newline in it is refused.
RELEASE_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
if ! [[ $RELEASE_ID =~ $RELEASE_ID_RE ]]; then
  echo "ERROR: RELEASE_ID must match ${RELEASE_ID_RE}" >&2
  exit 1
fi

if [ -z "$CONTINUO_TOKEN" ] \
   && { [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; }; then
  echo "ERROR: no bearer token available. Set CONTINUO_TOKEN (an operator's token), or run in a GitHub Actions job with 'permissions: id-token: write'." >&2
  exit 1
fi

DEADLINE=$((SECONDS + POLL_TIMEOUT_SECONDS))

RESP_FILE="$(mktemp)"
HDR_FILE="$(mktemp)"
trap 'rm -f "$RESP_FILE" "$HDR_FILE"' EXIT

# Outcome of the last call, set by run_curl, fetch_token and api.
HTTP_STATUS=""   # HTTP status code; 000 when no response was received
HTTP_BODY=""     # response body
CURL_RC=0        # curl's exit status
TOKEN=""         # the bearer token fetch_token produced
API_ERR=""       # set when the failure is not an HTTP answer (token request, deadline)
API_TRANSIENT=0  # 1 when the last call failed in a way a later attempt may fix

# curl_reason CODE: a short description of a curl exit status.
curl_reason() {
  case "$1" in
    3) echo "malformed URL" ;;
    6) echo "could not resolve host" ;;
    7) echo "connection refused" ;;
    28) echo "timed out" ;;
    35) echo "TLS handshake failed" ;;
    52) echo "empty reply from server" ;;
    55 | 56) echo "connection lost" ;;
    60) echo "TLS certificate verification failed" ;;
    *) echo "curl error" ;;
  esac
}

# is_transient: succeeds when the outcome in CURL_RC/HTTP_STATUS is one a later
# attempt may fix: a connection-level curl error, or HTTP 429/502/503/504.
is_transient() {
  if [ "$CURL_RC" -ne 0 ]; then
    case "$CURL_RC" in
      6 | 7 | 28 | 35 | 52 | 55 | 56) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$HTTP_STATUS" in
    429 | 502 | 503 | 504) return 0 ;;
    *) return 1 ;;
  esac
}

# describe_failure: the outcome of the last call as a phrase.
describe_failure() {
  if [ -n "$API_ERR" ]; then
    echo "$API_ERR"
  elif [ "$CURL_RC" -ne 0 ]; then
    echo "curl exit ${CURL_RC}: $(curl_reason "$CURL_RC")"
  else
    echo "HTTP ${HTTP_STATUS}"
  fi
}

# run_curl AUTH_HEADER URL [CURL_ARGS...]
#
# One HTTP request with a connect timeout and a total timeout capped by what is
# left of the budget. The authorization header goes to curl on stdin (-H @-), so
# it never appears in a process listing. Sets HTTP_STATUS, HTTP_BODY, CURL_RC;
# the response headers land in HDR_FILE.
run_curl() {
  local auth="$1" url="$2" remaining max_time rc=0
  shift 2
  remaining=$((DEADLINE - SECONDS))
  max_time=$((remaining < MAX_TIME ? remaining : MAX_TIME))
  [ "$max_time" -ge 1 ] || max_time=1
  : >"$RESP_FILE"
  : >"$HDR_FILE"
  HTTP_STATUS="$(printf '%s\n' "$auth" \
    | curl -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$max_time" \
      -o "$RESP_FILE" -D "$HDR_FILE" -w '%{http_code}' -H @- "$@" "$url")" || rc=$?
  CURL_RC=$rc
  [ "$rc" -eq 0 ] || HTTP_STATUS="000"
  HTTP_BODY="$(cat "$RESP_FILE")"
}

# fetch_token
#
# Sets TOKEN: CONTINUO_TOKEN when set, otherwise a fresh GitHub Actions OIDC
# token for AUDIENCE. Returns 0 on success, 1 when the request failed in a way a
# retry may fix (API_ERR says why), 2 when it did not.
fetch_token() {
  API_ERR=""
  if [ -n "$CONTINUO_TOKEN" ]; then
    TOKEN="$CONTINUO_TOKEN"
    return 0
  fi
  local audience_enc
  audience_enc="$(jq -rn --arg a "$AUDIENCE" '$a | @uri')"
  run_curl "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience_enc}" -H 'Accept: application/json'
  if [ "$HTTP_STATUS" = "200" ]; then
    TOKEN="$(jq -r '.value // empty' <<<"$HTTP_BODY" 2>/dev/null || true)"
    if [ -n "$TOKEN" ]; then
      return 0
    fi
    API_ERR="the GitHub Actions OIDC token endpoint returned no token"
    return 2
  fi
  API_ERR="could not obtain a GitHub Actions OIDC token ($(describe_failure))"
  if is_transient || [ "$HTTP_STATUS" -ge 500 ]; then
    return 1
  fi
  if [ "$CURL_RC" -eq 0 ]; then
    API_ERR="${API_ERR}; does the job grant 'permissions: id-token: write'?"
  fi
  return 2
}

# backoff STATUS ATTEMPT: seconds to wait before retry number ATTEMPT. A 429
# waits for its Retry-After header (whole seconds, at most 60), or
# RATE_LIMIT_DELAY without one; anything else waits RETRY_DELAY * ATTEMPT.
backoff() {
  local delay=""
  if [ "$1" = "429" ]; then
    delay="$(tr -d '\r' <"$HDR_FILE" | awk 'tolower($1) == "retry-after:" {print $2; exit}')"
    [[ $delay =~ ^[0-9]+$ ]] || delay="$RATE_LIMIT_DELAY"
    [ "$delay" -le 60 ] || delay=60
  else
    delay=$((RETRY_DELAY * $2))
  fi
  echo "$delay"
}

# api METHOD PATH [BODY]
#
# One authenticated call to continuo, returning 0 whatever the outcome so the
# caller decides what each one means; it sets HTTP_STATUS, HTTP_BODY, CURL_RC,
# API_ERR and API_TRANSIENT. A transient failure (see is_transient, plus a failed
# token request) is retried, API_TRIES tries in all, but never past DEADLINE; once
# retries run out API_TRANSIENT stays 1. Any other outcome returns at once.
api() {
  local method="$1" path="$2" body="${3:-}" attempt=1 rc delay
  local -a args
  while :; do
    API_TRANSIENT=0
    if [ $((DEADLINE - SECONDS)) -le 0 ]; then
      HTTP_STATUS="000"; CURL_RC=0; HTTP_BODY=""
      API_ERR="ran out of time (POLL_TIMEOUT_SECONDS=${POLL_TIMEOUT_SECONDS})"
      API_TRANSIENT=1
      return 0
    fi
    rc=0
    fetch_token || rc=$?
    if [ "$rc" -eq 0 ]; then
      args=(-X "$method" -H 'Accept: application/json')
      if [ -n "$body" ]; then
        args+=(-H 'Content-Type: application/json' -d "$body")
      fi
      run_curl "Authorization: Bearer ${TOKEN}" "${BASE_URL}${path}" "${args[@]}"
      if ! is_transient; then
        return 0
      fi
    else
      HTTP_STATUS="000"; HTTP_BODY=""
      if [ "$rc" -ne 1 ]; then
        return 0
      fi
    fi
    API_TRANSIENT=1
    delay="$(backoff "$HTTP_STATUS" "$attempt")"
    if [ "$attempt" -ge "$API_TRIES" ] || [ "$delay" -ge $((DEADLINE - SECONDS)) ]; then
      return 0
    fi
    echo "transient failure on ${method} ${path} ($(describe_failure)); retrying in ${delay}s (${attempt}/$((API_TRIES - 1)))" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# api_fail WHAT
#
# Reports a failed call: the HTTP status with the `code` and `error` of
# continuo's {error, code} answer, or the first 200 characters of the body when
# the answer is not that JSON (an ingress error page, say).
api_fail() {
  local what="$1" code error snippet
  if [ -n "$API_ERR" ]; then
    echo "ERROR: ${what} failed: ${API_ERR}" >&2
    return
  fi
  if [ "$HTTP_STATUS" = "000" ]; then
    if [ "$API_TRANSIENT" = "1" ]; then
      echo "ERROR: ${what} failed: could not reach ${BASE_URL} ($(describe_failure))" >&2
    else
      echo "ERROR: ${what} failed: $(describe_failure); not retried" >&2
    fi
    return
  fi
  code="$(jq -r '.code // empty' <<<"$HTTP_BODY" 2>/dev/null || true)"
  error="$(jq -r '.error // empty' <<<"$HTTP_BODY" 2>/dev/null || true)"
  echo "ERROR: ${what} failed: HTTP ${HTTP_STATUS} code=${code:-unknown} error=${error:-none}" >&2
  if [ -z "$code" ] && [ -n "$HTTP_BODY" ]; then
    snippet="$(printf '%s' "$HTTP_BODY" | head -c 200 | tr '\r\n' '  ')"
    echo "response body: ${snippet}" >&2
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

# Poll to a terminal status until DEADLINE: promoted succeeds; rejected and
# superseded fail. A poll that still fails transiently after its retries is
# skipped and tried again on the next attempt; any other error ends the run.
STATUS=""
LAST_STATUS=""
while [ $((DEADLINE - SECONDS)) -gt 0 ]; do
  api GET "/api/v1/releases/${RELEASE_ID}"
  if [ "$HTTP_STATUS" != "200" ]; then
    if [ "$API_TRANSIENT" = "1" ]; then
      echo "poll skipped: continuo unavailable ($(describe_failure))" >&2
      remaining=$((DEADLINE - SECONDS))
      sleep $((POLL_INTERVAL < remaining ? POLL_INTERVAL : (remaining > 0 ? remaining : 0)))
      continue
    fi
    api_fail "GET /api/v1/releases/${RELEASE_ID}"
    exit 1
  fi
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
  remaining=$((DEADLINE - SECONDS))
  sleep $((POLL_INTERVAL < remaining ? POLL_INTERVAL : (remaining > 0 ? remaining : 0)))
done
echo "timeout waiting for terminal status (last: ${STATUS:-unknown})" >&2
exit 1
