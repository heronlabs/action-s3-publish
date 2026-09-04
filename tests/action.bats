#!/usr/bin/env bats
# bats tests for core/publish.sh
#
# Builds a throwaway cwd with a dist folder, points an `aws` stub at PATH,
# runs the action script, and asserts on the logged aws calls / exit code.
# No network, no real AWS.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../core/publish.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/__mocks__"   # contains the `aws` stub
}

# Run the action script inside a throwaway cwd containing a populated dist folder.
# Puts the aws stub on PATH and captures the exit code plus the logged aws calls.
# Usage: run_action [VAR=value ...]
# Exports RUN_RC / RUN_OUT and leaves the call log at RUN_AWSLOG for the caller.
# shellcheck disable=SC2034  # RUN_OUT is used by callers in assertions
run_action() {
  local cwd; cwd="$(mktemp -d)"
  RUN_AWSLOG="$(mktemp)"
  : >"$RUN_AWSLOG"
  mkdir -p "$cwd/dist"
  printf 'hello\n' >"$cwd/dist/index.html"
  set +e
  RUN_OUT="$(
    cd "$cwd" &&
    env PATH="$STUB_DIR:$PATH" \
        AWS_LOG="$RUN_AWSLOG" \
        "$@" \
        bash "$SCRIPT" 2>&1
  )"
  RUN_RC=$?
  set -e
  rm -rf "$cwd"
}

line_of() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }

# ---------------------------------------------------------------- tests

@test "default acl: empties bucket then syncs with private acl" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist

  [ "$RUN_RC" -eq 0 ]
  grep -q 's3 rm s3://my-bucket --recursive' "$RUN_AWSLOG"
  grep -q 's3 sync ./dist s3://my-bucket' "$RUN_AWSLOG"
  grep 's3 sync' "$RUN_AWSLOG" | grep -q -- '--acl private'

  local rm_at sync_at
  rm_at="$(line_of "$RUN_AWSLOG" 's3 rm s3://my-bucket --recursive')"
  sync_at="$(line_of "$RUN_AWSLOG" 's3 sync ./dist s3://my-bucket')"
  [ -n "$rm_at" ] && [ -n "$sync_at" ] && [ "$rm_at" -lt "$sync_at" ]

  rm -f "$RUN_AWSLOG"
}

@test "public acl: sync uses --acl public-read" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PUBLIC_ACL=true

  [ "$RUN_RC" -eq 0 ]
  grep 's3 sync' "$RUN_AWSLOG" | grep -q -- '--acl public-read'

  rm -f "$RUN_AWSLOG"
}

@test "explicit false: falls back to --acl private" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PUBLIC_ACL=false

  [ "$RUN_RC" -eq 0 ]
  grep 's3 sync' "$RUN_AWSLOG" | grep -q -- '--acl private'

  rm -f "$RUN_AWSLOG"
}

@test "missing bucket: hard error, aws never invoked" {
  run_action BUILD_FOLDER=dist

  [ "$RUN_RC" -ne 0 ]
  [ ! -s "$RUN_AWSLOG" ]

  rm -f "$RUN_AWSLOG"
}

@test "missing build folder: hard error, aws never invoked" {
  run_action BUCKET_NAME=my-bucket

  [ "$RUN_RC" -ne 0 ]
  [ ! -s "$RUN_AWSLOG" ]

  rm -f "$RUN_AWSLOG"
}

@test "prune stale false: no bucket rm, sync without --delete" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_STALE=false

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 rm' "$RUN_AWSLOG")" -eq 0 ]
  grep -q 's3 sync ./dist s3://my-bucket' "$RUN_AWSLOG"
  [ "$(grep 's3 sync' "$RUN_AWSLOG" | grep -c -- '--delete')" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "prune stale default: bucket rm and sync --delete preserved" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist

  [ "$RUN_RC" -eq 0 ]
  grep -q 's3 rm s3://my-bucket --recursive' "$RUN_AWSLOG"
  grep 's3 sync' "$RUN_AWSLOG" | grep -q -- '--delete'

  rm -f "$RUN_AWSLOG"
}

@test "no cache html: two syncs, html gets no-cache, rest long cache" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist NO_CACHE_HTML=true

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 sync' "$RUN_AWSLOG")" -eq 2 ]
  grep 's3 sync' "$RUN_AWSLOG" | grep -- '--exclude \*.html' | grep -q -- '--cache-control max-age=31536000,public'
  grep 's3 sync' "$RUN_AWSLOG" | grep -- '--include \*.html' | grep -q -- '--cache-control no-cache'

  rm -f "$RUN_AWSLOG"
}

@test "no cache html default: single sync, one cache-control" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 sync' "$RUN_AWSLOG")" -eq 1 ]

  rm -f "$RUN_AWSLOG"
}

@test "no cache patterns: every pattern excluded from the long cache sync and included in the no-cache sync" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist NO_CACHE_PATTERNS='sw.js, manifest.webmanifest'

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 sync' "$RUN_AWSLOG")" -eq 2 ]
  grep 's3 sync' "$RUN_AWSLOG" | grep -- '--cache-control max-age=31536000,public' | grep -- '--exclude sw.js' | grep -q -- '--exclude manifest.webmanifest'
  grep 's3 sync' "$RUN_AWSLOG" | grep -- '--cache-control no-cache' | grep -- '--exclude \*' | grep -- '--include sw.js' | grep -q -- '--include manifest.webmanifest'
  [ "$(grep -c -- '--include  ' "$RUN_AWSLOG")" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "no cache patterns with no cache html: html joins the pattern list" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist NO_CACHE_HTML=true NO_CACHE_PATTERNS='sw.js'

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 sync' "$RUN_AWSLOG")" -eq 2 ]
  grep 's3 sync' "$RUN_AWSLOG" | grep -- '--cache-control max-age=31536000,public' | grep -- '--exclude \*.html' | grep -q -- '--exclude sw.js'
  grep 's3 sync' "$RUN_AWSLOG" | grep -- '--cache-control no-cache' | grep -- '--include \*.html' | grep -q -- '--include sw.js'

  rm -f "$RUN_AWSLOG"
}

@test "no cache patterns blank: single sync, one cache-control" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist NO_CACHE_PATTERNS=' , '

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 sync' "$RUN_AWSLOG")" -eq 1 ]
  [ "$(grep -c -- '--exclude' "$RUN_AWSLOG")" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}
