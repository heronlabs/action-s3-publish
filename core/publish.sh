#!/usr/bin/env bash

set -euo pipefail

: "${BUCKET_NAME:?BUCKET_NAME is required}"
: "${BUILD_FOLDER:?BUILD_FOLDER is required}"

ACL="private"
if [ "${PUBLIC_ACL:-}" = "true" ]; then
    ACL="public-read"
fi

SYNC_ARGS=()
if [ "${PRUNE_STALE:-true}" != "false" ]; then
    aws s3 rm "s3://${BUCKET_NAME}" --recursive
    SYNC_ARGS+=(--delete)
fi

NO_CACHE_EXCLUDES=()
NO_CACHE_INCLUDES=()
HAS_NO_CACHE_PATTERNS="false"

add_no_cache_pattern() {
    local pattern="$1"
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    if [ -z "${pattern}" ]; then
        return
    fi
    NO_CACHE_EXCLUDES+=(--exclude "${pattern}")
    NO_CACHE_INCLUDES+=(--include "${pattern}")
    HAS_NO_CACHE_PATTERNS="true"
}

if [ "${NO_CACHE_HTML:-}" = "true" ]; then
    add_no_cache_pattern "*.html"
fi

IFS=',' read -r -a NO_CACHE_PATTERN_LIST <<< "${NO_CACHE_PATTERNS:-}"
for pattern in ${NO_CACHE_PATTERN_LIST[@]+"${NO_CACHE_PATTERN_LIST[@]}"}; do
    add_no_cache_pattern "${pattern}"
done

if [ "${HAS_NO_CACHE_PATTERNS}" = "true" ]; then
    aws s3 sync "./${BUILD_FOLDER}" "s3://${BUCKET_NAME}" \
      "${NO_CACHE_EXCLUDES[@]}" \
      --cache-control max-age=31536000,public \
      ${SYNC_ARGS[@]+"${SYNC_ARGS[@]}"} \
      --storage-class=INTELLIGENT_TIERING \
      --acl "${ACL}"

    aws s3 sync "./${BUILD_FOLDER}" "s3://${BUCKET_NAME}" \
      --exclude "*" \
      "${NO_CACHE_INCLUDES[@]}" \
      --cache-control no-cache \
      ${SYNC_ARGS[@]+"${SYNC_ARGS[@]}"} \
      --storage-class=INTELLIGENT_TIERING \
      --acl "${ACL}"
else
    aws s3 sync "./${BUILD_FOLDER}" "s3://${BUCKET_NAME}" \
      --cache-control max-age=31536000,public \
      ${SYNC_ARGS[@]+"${SYNC_ARGS[@]}"} \
      --storage-class=INTELLIGENT_TIERING \
      --acl "${ACL}"
fi
