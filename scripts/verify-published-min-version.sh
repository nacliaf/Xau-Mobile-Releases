#!/usr/bin/env bash
set -euo pipefail

raw_tag="${1:-${RELEASE_TAG:-}}"

if [[ -z "$raw_tag" ]]; then
    echo "error: provide a release tag as the first argument or RELEASE_TAG" >&2
    exit 64
fi

expected_version="$raw_tag"
if [[ "$expected_version" == v* || "$expected_version" == V* ]]; then
    expected_version="${expected_version:1}"
fi

if [[ ! "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: release tag '$raw_tag' must be exactly MAJOR.MINOR.PATCH with an optional single leading v or V" >&2
    exit 64
fi

version_check_url="${VERSION_CHECK_URL:-https://clowningcrew.lol/api/version-check}"
max_attempts="${VERIFY_MAX_ATTEMPTS:-13}"
retry_interval_seconds="${VERIFY_RETRY_INTERVAL_SECONDS:-30}"
request_timeout_seconds="${VERIFY_REQUEST_TIMEOUT_SECONDS:-15}"
curl_bin="${CURL_BIN:-curl}"

if [[ ! "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: VERIFY_MAX_ATTEMPTS must be a positive integer" >&2
    exit 64
fi
if [[ ! "$retry_interval_seconds" =~ ^[0-9]+$ ]]; then
    echo "error: VERIFY_RETRY_INTERVAL_SECONDS must be a non-negative integer" >&2
    exit 64
fi
if [[ ! "$request_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: VERIFY_REQUEST_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to verify the backend response" >&2
    exit 69
fi
if ! command -v "$curl_bin" >/dev/null 2>&1; then
    echo "error: curl executable '$curl_bin' was not found" >&2
    exit 69
fi

body_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -f "$body_file" "$error_file"' EXIT

echo "Verifying published release v${expected_version} against ${version_check_url}"

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    : > "$body_file"
    : > "$error_file"

    if http_status="$(
        "$curl_bin" \
            --silent \
            --show-error \
            --location \
            --max-time "$request_timeout_seconds" \
            --output "$body_file" \
            --write-out '%{http_code}' \
            --header 'Accept: application/json' \
            --header 'User-Agent: XAUReleaseVerifier' \
            --header 'X-XAU: xaureleaseverifier' \
            --header "X-XAU-Version: $expected_version" \
            --header 'X-XAU-Protocol: 3' \
            --header 'X-XAU-Platform: release-verifier' \
            --header 'X-XAU-Client-Id: xau-release-verifier' \
            "$version_check_url" \
            2>"$error_file"
    )"; then
        if [[ "$http_status" == "200" ]]; then
            if ! jq -e . "$body_file" >/dev/null 2>&1; then
                echo "Attempt ${attempt}/${max_attempts}: HTTP 200, but response was not valid JSON" >&2
            elif observed_version="$(jq -er '(.data.minVersion? // .minVersion?) | select(type == "string")' "$body_file" 2>/dev/null)"; then
                if [[ "$observed_version" == "$expected_version" ]]; then
                    echo "Verified: backend minimum version is ${expected_version}"
                    exit 0
                fi
                echo "Attempt ${attempt}/${max_attempts}: expected ${expected_version}, received ${observed_version}" >&2
            else
                echo "Attempt ${attempt}/${max_attempts}: HTTP 200 JSON response did not contain minVersion" >&2
            fi
        else
            echo "Attempt ${attempt}/${max_attempts}: backend returned HTTP ${http_status:-unknown}" >&2
        fi
    else
        curl_error="$(head -n 1 "$error_file")"
        echo "Attempt ${attempt}/${max_attempts}: request failed${curl_error:+ ($curl_error)}" >&2
    fi

    if ((attempt < max_attempts)); then
        sleep "$retry_interval_seconds"
    fi
done

echo "error: backend minimum version did not become ${expected_version} after ${max_attempts} attempts" >&2
exit 1
