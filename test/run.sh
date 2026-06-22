#!/usr/bin/env bash
# Offline test harness for core/publish-s3-bucket.sh.
#
# Builds a throwaway cwd holding a populated build folder, points an `aws` stub at
# PATH, runs the action script, and asserts on the logged aws calls / exit code.
# No network, no real AWS.
#
# shellcheck disable=SC2015  # `cond && ok || bad` is intentional; ok() always returns 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../core/publish-s3-bucket.sh"
STUB_DIR="$HERE"   # contains the `aws` stub

pass=0
fail=0
note() { printf '  %s\n' "$*"; }
ok()   { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL - %s\n' "$1"; [ -n "${2:-}" ] && note "$2"; }

# Run the action script inside a throwaway cwd that contains a populated build folder.
# Puts the aws stub on PATH and captures the exit code plus the logged aws calls.
# Usage: run_action [VAR=value ...]   (env assignments handed straight to the script)
# Exports RUN_RC / RUN_OUT and leaves the call log at RUN_AWSLOG for the caller.
run_action() {
  local cwd; cwd="$(mktemp -d)"
  RUN_AWSLOG="$(mktemp)"
  : >"$RUN_AWSLOG"
  mkdir -p "$cwd/dist"
  printf 'hello\n' >"$cwd/dist/index.html"
  RUN_OUT="$(
    cd "$cwd" &&
    env PATH="$STUB_DIR:$PATH" \
        AWS_LOG="$RUN_AWSLOG" \
        "$@" \
        bash "$SCRIPT" 2>&1
  )"
  RUN_RC=$?
  rm -rf "$cwd"
}

line_of() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }   # <log> <pattern> -> 1-based line no

# ---------------------------------------------------------------- tests

test_default_acl_rm_before_sync() {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist

  [ "$RUN_RC" -eq 0 ] && ok "default acl: exit 0 (green)" || bad "default acl: exit 0 (green)" "rc=$RUN_RC out=$RUN_OUT"

  grep -q 's3 rm s3://my-bucket --recursive' "$RUN_AWSLOG" && ok "default acl: bucket emptied with rm --recursive" || bad "default acl: bucket emptied with rm --recursive" "$(cat "$RUN_AWSLOG")"
  grep -q 's3 sync ./dist s3://my-bucket' "$RUN_AWSLOG" && ok "default acl: build folder synced to bucket" || bad "default acl: build folder synced to bucket" "$(cat "$RUN_AWSLOG")"
  grep 's3 sync' "$RUN_AWSLOG" | grep -q -- '--acl private' && ok "default acl: sync uses --acl private" || bad "default acl: sync uses --acl private" "$(cat "$RUN_AWSLOG")"

  local rm_at sync_at
  rm_at="$(line_of "$RUN_AWSLOG" 's3 rm s3://my-bucket --recursive')"
  sync_at="$(line_of "$RUN_AWSLOG" 's3 sync ./dist s3://my-bucket')"
  [ -n "$rm_at" ] && [ -n "$sync_at" ] && [ "$rm_at" -lt "$sync_at" ] && ok "default acl: rm runs before sync" || bad "default acl: rm runs before sync" "rm@$rm_at sync@$sync_at"

  rm -f "$RUN_AWSLOG"
}

test_public_acl() {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PUBLIC_ACL=true

  [ "$RUN_RC" -eq 0 ] && ok "public acl: exit 0 (green)" || bad "public acl: exit 0 (green)" "rc=$RUN_RC out=$RUN_OUT"
  grep 's3 sync' "$RUN_AWSLOG" | grep -q -- '--acl public-read' && ok "public acl: sync uses --acl public-read" || bad "public acl: sync uses --acl public-read" "$(cat "$RUN_AWSLOG")"

  rm -f "$RUN_AWSLOG"
}

test_explicit_false_falls_back_to_private() {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PUBLIC_ACL=false

  [ "$RUN_RC" -eq 0 ] && ok "explicit false: exit 0 (green)" || bad "explicit false: exit 0 (green)" "rc=$RUN_RC out=$RUN_OUT"
  grep 's3 sync' "$RUN_AWSLOG" | grep -q -- '--acl private' && ok "explicit false: sync falls back to --acl private" || bad "explicit false: sync falls back to --acl private" "$(cat "$RUN_AWSLOG")"

  rm -f "$RUN_AWSLOG"
}

test_missing_bucket_hard_error() {
  run_action BUILD_FOLDER=dist

  [ "$RUN_RC" -ne 0 ] && ok "missing bucket: hard error (non-zero)" || bad "missing bucket: hard error (non-zero)" "rc=$RUN_RC out=$RUN_OUT"
  [ ! -s "$RUN_AWSLOG" ] && ok "missing bucket: aws never invoked" || bad "missing bucket: aws never invoked" "$(cat "$RUN_AWSLOG")"

  rm -f "$RUN_AWSLOG"
}

test_missing_build_folder_hard_error() {
  run_action BUCKET_NAME=my-bucket

  [ "$RUN_RC" -ne 0 ] && ok "missing build folder: hard error (non-zero)" || bad "missing build folder: hard error (non-zero)" "rc=$RUN_RC out=$RUN_OUT"
  [ ! -s "$RUN_AWSLOG" ] && ok "missing build folder: aws never invoked" || bad "missing build folder: aws never invoked" "$(cat "$RUN_AWSLOG")"

  rm -f "$RUN_AWSLOG"
}

# ---------------------------------------------------------------- run

test_default_acl_rm_before_sync
test_public_acl
test_explicit_false_falls_back_to_private
test_missing_bucket_hard_error
test_missing_build_folder_hard_error

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
