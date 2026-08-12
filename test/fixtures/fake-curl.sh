#!/usr/bin/env bash
set -euo pipefail

output_file=""
previous=""

for argument in "$@"; do
    if [[ "$previous" == "--output" ]]; then
        output_file="$argument"
    fi
    previous="$argument"
done

if [[ -z "$output_file" ]]; then
    echo "fake curl: --output was not provided" >&2
    exit 64
fi

: "${FAKE_CURL_BODY:?FAKE_CURL_BODY must be set}"
: "${FAKE_CURL_STATUS:=200}"

printf '%s' "$FAKE_CURL_BODY" > "$output_file"

if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
fi

if [[ -n "${FAKE_CURL_COUNT_FILE:-}" ]]; then
    count=0
    if [[ -f "$FAKE_CURL_COUNT_FILE" ]]; then
        read -r count < "$FAKE_CURL_COUNT_FILE"
    fi
    printf '%s\n' "$((count + 1))" > "$FAKE_CURL_COUNT_FILE"
fi

printf '%s' "$FAKE_CURL_STATUS"
