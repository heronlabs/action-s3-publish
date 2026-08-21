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

if [ "${NO_CACHE_HTML:-}" = "true" ]; then
    aws s3 sync "./${BUILD_FOLDER}" "s3://${BUCKET_NAME}" \
      --exclude "*.html" \
      --cache-control max-age=31536000,public \
      ${SYNC_ARGS[@]+"${SYNC_ARGS[@]}"} \
      --storage-class=INTELLIGENT_TIERING \
      --acl "${ACL}"

    aws s3 sync "./${BUILD_FOLDER}" "s3://${BUCKET_NAME}" \
      --exclude "*" \
      --include "*.html" \
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
