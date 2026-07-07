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
