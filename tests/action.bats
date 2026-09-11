#!/usr/bin/env bats
# bats tests for core/publish.sh
#
# Builds a throwaway cwd with a dist folder, points an `aws` stub at PATH,
# runs the action script, and asserts on the logged aws calls / exit code.
# No network, no real AWS.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../core/publish.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/__mocks__"   # contains the `aws` stub
  FIX_DIR="$(mktemp -d)"                     # per-test fixtures for the grace prune
  FIX_BUILD="$FIX_DIR/build.txt";  : >"$FIX_BUILD"    # extra dist files, one per line
  FIX_BUCKET="$FIX_DIR/bucket.txt"; : >"$FIX_BUCKET"  # bucket keys, one per line
  FIX_LEDGER="$FIX_DIR/ledger.in"                     # only exists once seed_ledger ran
  RUN_LEDGER_OUT="$FIX_DIR/ledger.out"                # ledger uploaded by the script
}

teardown() {
  rm -rf "$FIX_DIR"
}

# Fixture seeders for the grace prune. Call before run_action.
seed_build()  { printf '%s\n' "$@" >>"$FIX_BUILD"; }         # seed_build KEY...
seed_bucket() { printf '%s\n' "$@" >>"$FIX_BUCKET"; }        # seed_bucket KEY...
seed_ledger() { printf '%s\t%s\n' "$1" "$2" >>"$FIX_LEDGER"; } # seed_ledger KEY EPOCH

# Run the action script inside a throwaway cwd containing a populated dist folder.
# Puts the aws stub on PATH and captures the exit code plus the logged aws calls.
# Usage: run_action [VAR=value ...]
# Exports RUN_RC / RUN_OUT and leaves the call log at RUN_AWSLOG for the caller.
# Seeded fixtures (see seed_*) feed the stub: extra dist files are created, bucket
# keys and ledger go through AWS_BUCKET_KEYS_FILE / AWS_LEDGER_FILE, the uploaded
# ledger lands in RUN_LEDGER_OUT.
# shellcheck disable=SC2034  # RUN_OUT is used by callers in assertions
run_action() {
  local cwd; cwd="$(mktemp -d)"
  RUN_AWSLOG="$(mktemp)"
  : >"$RUN_AWSLOG"
  mkdir -p "$cwd/dist"
  printf 'hello\n' >"$cwd/dist/index.html"
  local f
  while IFS= read -r f; do
    mkdir -p "$cwd/dist/$(dirname "$f")"
    printf 'x\n' >"$cwd/dist/$f"
  done <"$FIX_BUILD"
  local stub_env=()
  if [ -f "$FIX_LEDGER" ]; then
    stub_env+=(AWS_LEDGER_FILE="$FIX_LEDGER")
  fi
  set +e
  RUN_OUT="$(
    cd "$cwd" &&
    env PATH="$STUB_DIR:$PATH" \
        AWS_LOG="$RUN_AWSLOG" \
        AWS_BUCKET_KEYS_FILE="$FIX_BUCKET" \
        AWS_LEDGER_OUT="$RUN_LEDGER_OUT" \
        ${stub_env[@]+"${stub_env[@]}"} \
        "$@" \
        bash "$SCRIPT" 2>&1
  )"
  RUN_RC=$?
  set -e
  rm -rf "$cwd"
}

line_of() { grep -n "$2" "$1" | head -1 | cut -d: -f1; }
last_line_of() { grep -n "$2" "$1" | tail -1 | cut -d: -f1; }

# Epoch seconds N days ago (integer math only, portable between BSD and GNU date).
days_ago() { echo $(( $(date -u +%s) - $1 * 86400 )); }

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

# ---------------------------------------------------------------- grace prune

@test "grace set: no bucket rm, sync without --delete, prune runs after the last sync" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7 NO_CACHE_HTML=true

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 rm' "$RUN_AWSLOG")" -eq 0 ]
  [ "$(grep -c 's3 sync' "$RUN_AWSLOG")" -eq 2 ]
  [ "$(grep 's3 sync' "$RUN_AWSLOG" | grep -c -- '--delete')" -eq 0 ]

  local sync_at list_at upload_at
  sync_at="$(last_line_of "$RUN_AWSLOG" 's3 sync ./dist s3://my-bucket')"
  list_at="$(line_of "$RUN_AWSLOG" 's3api list-objects-v2 --bucket my-bucket')"
  upload_at="$(line_of "$RUN_AWSLOG" 's3 cp - s3://my-bucket/.s3-publish/stale.tsv')"
  [ -n "$sync_at" ] && [ -n "$list_at" ] && [ -n "$upload_at" ]
  [ "$sync_at" -lt "$list_at" ] && [ "$list_at" -lt "$upload_at" ]
  grep 's3 cp - s3://my-bucket/.s3-publish/stale.tsv' "$RUN_AWSLOG" | grep -- '--cache-control no-cache' | grep -q -- '--acl private'

  rm -f "$RUN_AWSLOG"
}

@test "grace with prune stale false: accepted" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7 PRUNE_STALE=false

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3 rm' "$RUN_AWSLOG")" -eq 0 ]

  rm -f "$RUN_AWSLOG"
}

@test "grace first run, no ledger: nothing deleted, every stale key stamped now" {
  seed_bucket index.html old-a.js old-b.js
  local before after
  before="$(date -u +%s)"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7
  after="$(date -u +%s)"

  [ "$RUN_RC" -eq 0 ]
  grep -q 's3 ls s3://my-bucket/.s3-publish/stale.tsv' "$RUN_AWSLOG"
  [ "$(grep -c 's3 cp s3://my-bucket/.s3-publish/stale.tsv -' "$RUN_AWSLOG")" -eq 0 ]
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 0 ]
  [ "$(wc -l <"$RUN_LEDGER_OUT")" -eq 2 ]
  [ "$(grep -c '^index.html' "$RUN_LEDGER_OUT")" -eq 0 ]
  local key ts
  while IFS=$'\t' read -r key ts; do
    case "$key" in old-a.js|old-b.js) : ;; *) return 1 ;; esac
    [ "$ts" -ge "$before" ] && [ "$ts" -le "$after" ]
  done <"$RUN_LEDGER_OUT"

  rm -f "$RUN_AWSLOG"
}

@test "grace expired: stale key older than grace deleted and dropped from ledger" {
  seed_bucket index.html old.js
  seed_ledger old.js "$(days_ago 8)"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7

  [ "$RUN_RC" -eq 0 ]
  grep -q 's3 cp s3://my-bucket/.s3-publish/stale.tsv -' "$RUN_AWSLOG"
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 1 ]
  grep 's3api delete-objects --bucket my-bucket' "$RUN_AWSLOG" | grep -q -- '--delete {"Objects":\[{"Key":"old.js"}\],"Quiet":true}'
  printf '%s\n' "$RUN_OUT" | grep -q 'deleted s3://my-bucket/old.js'
  [ ! -s "$RUN_LEDGER_OUT" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace young: stale key younger than grace kept, timestamp preserved" {
  local since; since="$(days_ago 1)"
  seed_bucket index.html young.js
  seed_ledger young.js "$since"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 0 ]
  [ "$(cat "$RUN_LEDGER_OUT")" = "young.js	$since" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace rollback: key in ledger but back in build not deleted, dropped from ledger" {
  seed_build back.js
  seed_bucket index.html back.js
  seed_ledger back.js "$(days_ago 30)"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 0 ]
  [ ! -s "$RUN_LEDGER_OUT" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace build keys never deleted, nested paths included" {
  seed_build assets/app.js assets/chunk.js
  seed_bucket index.html assets/app.js assets/chunk.js
  seed_ledger assets/app.js "$(days_ago 365)"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=1

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 0 ]
  [ ! -s "$RUN_LEDGER_OUT" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace ledger key itself never listed as stale nor deleted" {
  seed_bucket index.html .s3-publish/stale.tsv
  seed_ledger .s3-publish/stale.tsv "$(days_ago 365)"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 0 ]
  [ ! -s "$RUN_LEDGER_OUT" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace empty bucket: no delete call, empty ledger uploaded" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 0 ]
  grep -q 's3 cp - s3://my-bucket/.s3-publish/stale.tsv' "$RUN_AWSLOG"
  [ -f "$RUN_LEDGER_OUT" ] && [ ! -s "$RUN_LEDGER_OUT" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace ledger download fails: hard error, no delete, no ledger upload" {
  seed_bucket index.html old.js
  seed_ledger old.js "$(days_ago 30)"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7 AWS_LEDGER_DOWNLOAD_FAIL=1

  [ "$RUN_RC" -ne 0 ]
  grep -q 's3 cp s3://my-bucket/.s3-publish/stale.tsv -' "$RUN_AWSLOG"
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 0 ]
  [ "$(grep -c 's3 cp - s3://my-bucket/.s3-publish/stale.tsv' "$RUN_AWSLOG")" -eq 0 ]
  [ ! -f "$RUN_LEDGER_OUT" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace over 1000 expired keys: multiple delete-objects batches" {
  local since i; since="$(days_ago 30)"
  seed_bucket index.html
  for i in $(seq 1 1001); do
    seed_bucket "chunk-$i.js"
    seed_ledger "chunk-$i.js" "$since"
  done
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7

  [ "$RUN_RC" -eq 0 ]
  [ "$(grep -c 's3api delete-objects' "$RUN_AWSLOG")" -eq 2 ]
  [ "$(grep -o '{"Key":"chunk-[0-9]*.js"}' "$RUN_AWSLOG" | sort -u | wc -l)" -eq 1001 ]
  [ "$(printf '%s\n' "$RUN_OUT" | grep -c 'deleted s3://my-bucket/chunk-')" -eq 1001 ]
  [ ! -s "$RUN_LEDGER_OUT" ]

  rm -f "$RUN_AWSLOG"
}

@test "grace json escaping: quotes and backslashes in keys escaped in the delete payload" {
  seed_bucket index.html 'we"ird\key.js'
  seed_ledger 'we"ird\key.js' "$(days_ago 30)"
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7

  [ "$RUN_RC" -eq 0 ]
  grep 's3api delete-objects' "$RUN_AWSLOG" | grep -qF -- '{"Key":"we\"ird\\key.js"}'

  rm -f "$RUN_AWSLOG"
}

@test "grace invalid value: hard error, aws never invoked" {
  local value
  for value in 0 abc 7.5 -3; do
    run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist "PRUNE_GRACE_DAYS=$value"
    [ "$RUN_RC" -ne 0 ]
    [ ! -s "$RUN_AWSLOG" ]
    rm -f "$RUN_AWSLOG"
  done
}

@test "grace with prune stale true: hard error, aws never invoked" {
  run_action BUCKET_NAME=my-bucket BUILD_FOLDER=dist PRUNE_GRACE_DAYS=7 PRUNE_STALE=true

  [ "$RUN_RC" -ne 0 ]
  [ ! -s "$RUN_AWSLOG" ]
  printf '%s\n' "$RUN_OUT" | grep -q 'PRUNE_STALE'

  rm -f "$RUN_AWSLOG"
}
