#!/usr/bin/env bash

set -euo pipefail

: "${BUCKET_NAME:?BUCKET_NAME is required}"
: "${BUILD_FOLDER:?BUILD_FOLDER is required}"

ACL="private"
if [ "${PUBLIC_ACL:-}" = "true" ]; then
    ACL="public-read"
fi

aws s3 rm "s3://${BUCKET_NAME}" --recursive

aws s3 sync "./${BUILD_FOLDER}" "s3://${BUCKET_NAME}" \
  --cache-control max-age=31536000,public \
  --delete \
  --storage-class=INTELLIGENT_TIERING \
  --acl "${ACL}"
