#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/verify-published-min-version.sh"
FAKE_CURL="$ROOT_DIR/test/fixtures/fake-curl.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

passed=0
failed=0

run_case() {
    local name="$1"
    shift

    if "$@"; then
        printf 'ok - %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'not ok - %s\n' "$name"
        failed=$((failed + 1))
    fi
}

run_verifier() {
    local fake_body="${FAKE_CURL_BODY-}"
    if [[ -z "$fake_body" ]]; then
        fake_body='{"success":true,"minVersion":"4.1.1"}'
    fi

    env \
        CURL_BIN="$FAKE_CURL" \
        VERIFY_MAX_ATTEMPTS="${VERIFY_MAX_ATTEMPTS:-1}" \
        VERIFY_RETRY_INTERVAL_SECONDS=0 \
        VERSION_CHECK_URL="${VERSION_CHECK_URL:-https://example.test/api/version-check}" \
        RELEASE_TAG="${RELEASE_TAG:-}" \
        FAKE_CURL_BODY="$fake_body" \
        FAKE_CURL_STATUS="${FAKE_CURL_STATUS:-200}" \
        FAKE_CURL_LOG="${FAKE_CURL_LOG:-}" \
        FAKE_CURL_COUNT_FILE="${FAKE_CURL_COUNT_FILE:-}" \
        "$SCRIPT" "$@"
}

accepts_release_tag_from_environment() {
    local output
    output="$(RELEASE_TAG=v4.1.1 run_verifier 2>&1)"
    [[ "$output" == *"minimum version is 4.1.1"* ]]
}

accepts_exact_version() {
    local output
    output="$(run_verifier 4.1.1 2>&1)"
    [[ "$output" == *"minimum version is 4.1.1"* ]]
}

accepts_one_leading_v_and_sends_identity_headers() {
    local curl_log="$TEST_TMP/curl.log"
    FAKE_CURL_LOG="$curl_log" run_verifier V4.1.1 >/dev/null 2>&1
    grep -Fq -- 'X-XAU-Version: 4.1.1' "$curl_log" &&
        grep -Fq -- 'X-XAU-Platform: release-verifier' "$curl_log" &&
        grep -Fq -- 'X-XAU-Client-Id: xau-release-verifier' "$curl_log" &&
        grep -Fq -- 'X-XAU: xaureleaseverifier' "$curl_log" &&
        grep -Fq -- 'https://example.test/api/version-check' "$curl_log"
}

workflow_runs_verifier_for_published_releases() {
    local workflow="$ROOT_DIR/.github/workflows/verify-min-version.yml"
    [[ -f "$workflow" ]] &&
        grep -Fq 'types: [published]' "$workflow" &&
        grep -Fq 'permissions:' "$workflow" &&
        grep -Fq 'contents: read' "$workflow" &&
        grep -Fq 'github.event.release.tag_name' "$workflow" &&
        grep -Fq 'scripts/verify-published-min-version.sh' "$workflow"
}

rejects_malformed_tag_before_network_request() {
    local curl_count="$TEST_TMP/malformed-count"
    if FAKE_CURL_COUNT_FILE="$curl_count" run_verifier vv4.1.1 >/dev/null 2>&1; then
        return 1
    fi
    [[ ! -e "$curl_count" ]]
}

retries_then_fails_on_mismatch() {
    local curl_count="$TEST_TMP/mismatch-count"
    local output
    if output="$(
        VERIFY_MAX_ATTEMPTS=2 \
        FAKE_CURL_BODY='{"success":true,"minVersion":"4.1.0"}' \
        FAKE_CURL_COUNT_FILE="$curl_count" \
        run_verifier v4.1.1 2>&1
    )"; then
        return 1
    fi
    [[ "$(<"$curl_count")" == "2" && "$output" == *"expected 4.1.1, received 4.1.0"* ]]
}

retries_then_fails_on_non_json() {
    local curl_count="$TEST_TMP/non-json-count"
    local output
    if output="$(
        VERIFY_MAX_ATTEMPTS=2 \
        FAKE_CURL_BODY='<html>temporarily unavailable</html>' \
        FAKE_CURL_COUNT_FILE="$curl_count" \
        run_verifier 4.1.1 2>&1
    )"; then
        return 1
    fi
    [[ "$(<"$curl_count")" == "2" && "$output" == *"response was not valid JSON"* ]]
}

run_case 'accepts an exact MAJOR.MINOR.PATCH minimum' accepts_exact_version
run_case 'accepts the release tag from the environment' accepts_release_tag_from_environment
run_case 'strips one leading v or V and sends client identity headers' accepts_one_leading_v_and_sends_identity_headers
run_case 'rejects malformed tags before making a request' rejects_malformed_tag_before_network_request
run_case 'retries and fails when the backend minimum mismatches' retries_then_fails_on_mismatch
run_case 'retries and fails when the backend response is not JSON' retries_then_fails_on_non_json
run_case 'runs after a GitHub release is published' workflow_runs_verifier_for_published_releases

printf '%s passed; %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
