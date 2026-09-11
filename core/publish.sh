#!/usr/bin/env bash

set -euo pipefail

: "${BUCKET_NAME:?BUCKET_NAME is required}"
: "${BUILD_FOLDER:?BUILD_FOLDER is required}"

ACL="private"
if [ "${PUBLIC_ACL:-}" = "true" ]; then
    ACL="public-read"
fi

if [ -n "${PRUNE_GRACE_DAYS:-}" ]; then
    if ! [[ "${PRUNE_GRACE_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
        echo "PRUNE_GRACE_DAYS must be a positive integer, got '${PRUNE_GRACE_DAYS}'" >&2
        exit 1
    fi
    if [ "${PRUNE_STALE:-}" = "true" ]; then
        echo "PRUNE_GRACE_DAYS cannot be combined with PRUNE_STALE=true" >&2
        exit 1
    fi
fi

SYNC_ARGS=()
if [ -z "${PRUNE_GRACE_DAYS:-}" ] && [ "${PRUNE_STALE:-true}" != "false" ]; then
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

# ---------------------------------------------------------------- grace prune
#
# Ledger object `.s3-publish/stale.tsv`: one `<key>\t<stale-since-epoch>` per
# bucket key absent from the build. Keys stay in the bucket until they have
# been absent for PRUNE_GRACE_DAYS, then get deleted. Keys in the build are
# never deleted. Portable to bash 3.2 (macOS) + BSD/GNU coreutils.

LEDGER_KEY=".s3-publish/stale.tsv"
DELETE_BATCH_SIZE=1000

# Download the ledger into $1. Absent ledger -> empty file. Present but
# unreadable -> abort (never treat a read error as "empty": that resets every clock).
read_ledger() {
    if aws s3 ls "s3://${BUCKET_NAME}/${LEDGER_KEY}" >/dev/null; then
        aws s3 cp "s3://${BUCKET_NAME}/${LEDGER_KEY}" - >"$1"
    else
        : >"$1"
    fi
}

# Every key in the bucket, one per line, into $1. Empty bucket -> empty file.
list_bucket_keys() {
    local raw="$1.raw"
    aws s3api list-objects-v2 --bucket "${BUCKET_NAME}" \
      --query 'Contents[].Key' --output text >"${raw}"
    tr '\t' '\n' <"${raw}" | grep -v -e '^None$' -e '^$' >"$1" || true
    rm -f "${raw}"
}

# Every regular file under BUILD_FOLDER, path relative to it, into $1.
list_build_files() {
    (cd "./${BUILD_FOLDER}" && find . -type f | sed 's|^\./||') >"$1"
}

# Delete the keys listed in $1 (one per line) in batches of DELETE_BATCH_SIZE.
delete_keys() {
    local batch=() key
    while IFS= read -r key; do
        batch+=("${key}")
        if [ "${#batch[@]}" -ge "${DELETE_BATCH_SIZE}" ]; then
            delete_batch "${batch[@]}"
            batch=()
        fi
    done <"$1"
    if [ "${#batch[@]}" -gt 0 ]; then
        delete_batch "${batch[@]}"
    fi
}

# Payload goes through a file: 1000 keys inline would blow past the per-argument
# size limit (128 KiB on Linux) once keys get long.
delete_batch() {
    local objects="" key escaped payload="${PRUNE_WORK}/delete-batch.json"
    for key in "$@"; do
        escaped="${key//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        objects="${objects:+${objects},}{\"Key\":\"${escaped}\"}"
    done
    printf '{"Objects":[%s],"Quiet":true}' "${objects}" >"${payload}"
    aws s3api delete-objects --bucket "${BUCKET_NAME}" \
      --delete "file://${payload}"
    for key in "$@"; do
        printf 'deleted s3://%s/%s\n' "${BUCKET_NAME}" "${key}"
    done
}

prune_stale_keys() {
    local days="$1"
    local now cutoff work
    now="$(date -u +%s)"
    cutoff=$(( now - days * 86400 ))
    PRUNE_WORK="$(mktemp -d)"
    trap 'rm -rf "${PRUNE_WORK}"' EXIT
    work="${PRUNE_WORK}"

    read_ledger "${work}/old.tsv"
    list_bucket_keys "${work}/bucket.txt"
    list_build_files "${work}/build.txt"
    printf '%s\n' "${LEDGER_KEY}" >>"${work}/build.txt"

    # stale = bucket - build - ledger key
    LC_ALL=C sort -u "${work}/bucket.txt" >"${work}/bucket.sorted"
    LC_ALL=C sort -u "${work}/build.txt" >"${work}/build.sorted"
    LC_ALL=C comm -23 "${work}/bucket.sorted" "${work}/build.sorted" >"${work}/stale.txt"

    # stale-since: keep the old ledger timestamp, otherwise stamp now
    awk -F '\t' -v now="${now}" -v ledger="${work}/old.tsv" '
        FILENAME == ledger { since[$1] = $2; next }
        { print $1 "\t" (($1 in since) ? since[$1] : now) }
    ' "${work}/old.tsv" "${work}/stale.txt" >"${work}/stale.tsv"

    awk -F '\t' -v cutoff="${cutoff}" '($2 + 0) < (cutoff + 0) { print $1 }' \
      "${work}/stale.tsv" >"${work}/expired.txt"
    awk -F '\t' -v cutoff="${cutoff}" '($2 + 0) >= (cutoff + 0)' \
      "${work}/stale.tsv" >"${work}/new.tsv"

    delete_keys "${work}/expired.txt"

    aws s3 cp - "s3://${BUCKET_NAME}/${LEDGER_KEY}" \
      --cache-control no-cache \
      --acl private <"${work}/new.tsv"
}

if [ -n "${PRUNE_GRACE_DAYS:-}" ]; then
    prune_stale_keys "${PRUNE_GRACE_DAYS}"
fi
