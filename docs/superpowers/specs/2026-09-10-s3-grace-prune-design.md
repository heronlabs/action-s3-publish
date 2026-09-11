# action-s3-publish — grace-period prune (`PRUNE_GRACE_DAYS`)

Date: 2026-09-10
Status: approved design, pending implementation plan

## Problem

`PRUNE_STALE` is binary:

- `true` (default): `aws s3 rm --recursive` + `aws s3 sync --delete`. Old hashed chunks vanish at deploy time. Open tabs and returning visitors holding an old `index.html` hit 404 (or a CloudFront 200/HTML) on lazy chunks.
- `false`: nothing is ever deleted. Every chunk ever shipped stays in the bucket forever. This is what `sonhandoape/webapps` runs today (`PRUNE_STALE: 'false'` + `NO_CACHE_HTML: 'true'`).

Goal: keep `index.html` no-cache and old versions servable for a grace window, then delete objects the current build no longer references.

"Referenced by the current index" is approximated by "present in `BUILD_FOLDER`": lazy chunks are referenced from other chunks, not from `index.html`, and the build folder is exactly the transitive closure.

## Rejected alternatives

- **`LastModified`-based prune (no state).** `LastModified` records the last deploy that *shipped* a key, not when it went stale. A client that deploys every 30 days would delete the previous version's chunks on the very next deploy, breaking a tab opened the day before. Wrong clock.
- **S3 lifecycle rule in cloud-iac (expire unmodified > N days).** A site not deployed for N+1 days loses its live objects. No build-membership check. Fatal.
- **Bucket versioning + noncurrent expiry.** Delete markers still 404 old tabs.
- **Deploy manifests / object tags.** Correct, but more state (one object per deploy) or one tagging API call per stale key per deploy. The ledger below gives the same guarantee with one object.

## Design

### New input

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `PRUNE_GRACE_DAYS` | No | unset | Positive integer. When set: no bucket wipe, no `--delete`; after the sync, objects absent from `BUILD_FOLDER` are recorded in a ledger and deleted once they have been absent for at least this many days. |

Validation (hard error, `aws` never invoked):

- `PRUNE_GRACE_DAYS` set but not matching `^[1-9][0-9]*$`.
- `PRUNE_GRACE_DAYS` set and `PRUNE_STALE` explicitly `true` (contradictory). `PRUNE_STALE` unset or `false` alongside is fine.

Unset `PRUNE_GRACE_DAYS` → behavior identical to v5.1.0. Minor release (`feat:`), CD bumps `v5.2.x`, floating `v5` moves.

### Ledger

Object key: `.s3-publish/stale.tsv` in the destination bucket. One line per stale key:

```
<key>\t<stale-since-epoch-seconds>
```

Epoch seconds (not ISO) so timestamp math is plain integer arithmetic and portable between GNU and BSD `date` (bats runs on macOS locally, ubuntu in CI).

Uploaded with `--cache-control no-cache --acl private` (the action already uses `--acl private` on the same bucket, so ACL support is known to be enabled). Publicly fetchable through CloudFront like any object; it exposes only the names of old chunks, which is no more than a previous `index.html` already exposed.

### Flow when `PRUNE_GRACE_DAYS` is set

1. Validate inputs (above).
2. Skip `aws s3 rm`; sync passes run exactly as today (cache-control split, storage class, ACL) without `--delete`.
3. Prune, only after every sync pass succeeded (`set -e`):
   1. `now` = current epoch seconds; `cutoff = now - PRUNE_GRACE_DAYS * 86400`.
   2. Read the ledger. Check presence first (`aws s3 ls` on the exact key); if absent, ledger is empty. If present, download it; a download failure aborts the run (never treat a read error as "empty" — that would reset every clock).
   3. List every key in the bucket (paginated by the CLI). Keys are handled one per line.
   4. `build` = every regular file under `BUILD_FOLDER`, path relative to it (same thing `aws s3 sync` uploads).
   5. `stale` = bucket keys − `build` − `{.s3-publish/stale.tsv}`.
   6. For each stale key: if present in the old ledger keep its `stale-since`, otherwise `stale-since = now`.
   7. `expired` = stale keys with `stale-since < cutoff`. Delete them with `aws s3api delete-objects` in batches of up to 1000 keys (keys JSON-escaped). Log every deleted key.
   8. New ledger = stale − expired. Ledger entries whose key is back in the build (rollback) or no longer in the bucket are dropped implicitly.
   9. Upload the new ledger (always, even when empty).

Keys in the current build are never deleted, whatever their age or ledger state.

### Guarantees and caveats

- A chunk survives at least `PRUNE_GRACE_DAYS` after the first deploy that stopped shipping it, independent of deploy cadence.
- Prune only runs at deploy time. A rarely deployed site keeps its junk until the next deploy after the grace window. Never breaks tabs; only delays cleanup.
- **First run** on a bucket full of junk deletes nothing. Every stale key is stamped `now` and removed on the first deploy at least `PRUNE_GRACE_DAYS` later.
- Does not depend on `aws s3 sync` re-uploading unchanged files or on `LastModified`.
- IAM: role needs `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on the bucket. cloud-iac `web-server` grants `s3:*`; README policy block gains `s3:GetObject`.

### Out of scope

- The `aws s3 rm` empty-bucket window for clients on default `PRUNE_STALE` (unchanged).
- cloud-iac CloudFront `customErrorResponses` with `errorCachingMinTtl: 86400` (deleted chunk URL served as 200/HTML and edge-cached 24h). Tracked as a separate cloud-iac issue.

## Files touched (action-s3-publish)

- `action.yml` — `PRUNE_GRACE_DAYS` input + env passthrough.
- `core/publish.sh` — validation, skip wipe/`--delete`, prune step. Keep the script single-file; prune logic in functions.
- `tests/__mocks__/aws` — add `s3 ls <key>`, `s3 cp` (download/upload ledger via fixture files), `s3api list-objects-v2` (keys from a fixture), `s3api delete-objects` (logged). Fixtures via env vars so each test controls bucket contents and ledger.
- `tests/action.bats` — new cases:
  - grace set: no `s3 rm`, no `--delete`, prune runs after the last sync.
  - first run, no ledger: nothing deleted, ledger written with every stale key stamped `now`.
  - stale key in ledger older than grace: deleted, dropped from ledger.
  - stale key in ledger younger than grace: kept, timestamp preserved (not re-stamped).
  - key in ledger but back in build: not deleted, dropped from ledger.
  - key in build with old ledger entry: never deleted.
  - ledger key itself never listed as stale / never deleted.
  - bucket empty: no delete call, empty ledger uploaded.
  - ledger present but download fails: hard error, no delete, no ledger upload.
  - more than 1000 expired keys: multiple `delete-objects` batches.
  - `PRUNE_GRACE_DAYS=0`, `abc`: hard error, `aws` never invoked.
  - `PRUNE_GRACE_DAYS=7` + `PRUNE_STALE=true`: hard error.
  - grace unset: existing tests unchanged.
- `README.md` — inputs table, "How it works" step, Notes (ledger path, first-run behavior, cadence caveat), IAM policy adds `s3:GetObject`. Soften "Destructive" note: applies only when `PRUNE_GRACE_DAYS` is unset and `PRUNE_STALE` is not `false`.

## Consumer rollout

`sonhandoape/webapps` `.github/actions/continuous-deployment/action.yaml`, after `v5.2` is released: replace `PRUNE_STALE: 'false'` with `PRUNE_GRACE_DAYS: '7'`. Keep `NO_CACHE_HTML` and `NO_CACHE_PATTERNS`.

## Delivery

1. `/supera:ship` on `action-s3-publish` (worktree → PR → pr-watch). Includes this spec.
2. After merge and release, PR on `sonhandoape/webapps`.
3. cloud-iac follow-up issue (already filed, see out of scope).
