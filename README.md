# 🪣 action-s3-publish — Sync folder to S3 bucket

[![CI][ci-badge]][ci-url]
[![License: MIT][license-badge]][license-url]
[![GitHub Marketplace][marketplace-badge]][marketplace-url]

> **GitHub Action** to sync a build folder to an S3 bucket for website-style static hosting.

Empties the destination bucket, then uploads everything under `BUILD_FOLDER` with long-lived cache headers and `INTELLIGENT_TIERING` storage. Authenticates via OIDC.

## Contents

- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Permissions](#permissions)
- [Architecture](#architecture)
- [How it works](#how-it-works)
- [Notes](#notes)
- [License](#license)

## Usage

```yaml
name: Publish Web

on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  publish:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7

      - name: Build
        run: npm ci && npm run build

      - name: Publish to S3
        uses: heronlabs/action-s3-publish@v3
        with:
          AWS_ROLE_TO_ASSUME: ${{ secrets.AWS_ROLE_ARN }}
          AWS_REGION: us-east-1
          AWS_ROLE_DURATION_SECONDS: 900
          BUILD_FOLDER: dist
          BUCKET_NAME: my-site-bucket

      - name: Invalidate CloudFront
        uses: heronlabs/action-cloudfront-publish@v3
        with:
          AWS_ROLE_TO_ASSUME: ${{ secrets.AWS_ROLE_ARN }}
          AWS_REGION: us-east-1
          AWS_ROLE_DURATION_SECONDS: 900
          DISTRIBUTION_ID: E1ABCDEF2GHIJK
```

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `AWS_ROLE_TO_ASSUME` | ARN of the IAM role to assume via OIDC. | Yes | — |
| `AWS_REGION` | AWS region where the S3 bucket lives. | Yes | — |
| `AWS_ROLE_DURATION_SECONDS` | Duration in seconds for the assumed role session. | Yes | — |
| `BUILD_FOLDER` | Local folder (relative to the repo root) whose contents should be published. | Yes | — |
| `BUCKET_NAME` | Destination S3 bucket name. | Yes | — |
| `PUBLIC_ACL` | Set to `"true"` to apply `public-read` ACL. | No | `private` |
| `PRUNE_STALE` | Set to `"false"` to keep previously published objects: skips the bucket wipe and `--delete`, so hashed assets from earlier deploys stay servable. | No | `true` |
| `NO_CACHE_HTML` | Set to `"true"` to publish `*.html` with `cache-control no-cache`. | No | — |
| `NO_CACHE_PATTERNS` | Comma-separated `aws s3 sync` patterns, matched against paths relative to `BUILD_FOLDER`, published with `cache-control no-cache`. Adds to `NO_CACHE_HTML`. Use it for files served at a fixed URL, such as a service worker or a web app manifest. | No | — |

## Outputs

This action produces no outputs.

## Permissions

```yaml
permissions:
  id-token: write
  contents: read
```

<details><summary>AWS IAM policy</summary>

The assumed role must allow listing, deleting, and putting objects in the target bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:DeleteObject", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::<bucket-name>",
        "arn:aws:s3:::<bucket-name>/*"
      ]
    }
  ]
}
```

</details>

## Architecture

Bash shell script wrapped by a composite GitHub Action.

```
├── action.yml                    # Composite action definition
├── core/
│   └── publish.sh                # CLI entry point — S3 bucket sync
├── tests/
│   ├── __mocks__/
│   │   └── aws                   # AWS CLI stub (records invocations)
│   └── action.bats               # BATS tests
├── Makefile                      # test (bats) + lint (shellcheck)
└── version.txt                   # Current version
```

## How it works

Composite action with a single shell script (`core/publish.sh`):

1. **Validate inputs** — `BUCKET_NAME` and `BUILD_FOLDER` must be set.
2. **Empty the target** — runs `aws s3 rm --recursive` on the destination bucket.
3. **Upload statics** — runs `aws s3 sync` from `BUILD_FOLDER` with cache headers (`max-age=31536000`), `INTELLIGENT_TIERING` storage class, and the configured ACL (`private` by default, `public-read` when `PUBLIC_ACL=true`).
4. **Split the cache header** — when `NO_CACHE_HTML` or `NO_CACHE_PATTERNS` is set, the sync runs twice: once excluding the listed patterns with the long-lived header, once including only them with `cache-control no-cache`.

Authenticates via `aws-actions/configure-aws-credentials` with an OIDC role.

## Notes

- **Destructive**: empties the bucket via `aws s3 rm --recursive` before uploading. Never point it at a bucket holding non-static files.
- Uploads with long cache headers (`max-age=31536000`) and `INTELLIGENT_TIERING`. Pair with a CloudFront invalidation after each deploy, or use content-hashed filenames.
- Files that keep the same name across deploys (`index.html`, `sw.js`, `manifest.webmanifest`) need `NO_CACHE_HTML` or `NO_CACHE_PATTERNS`, otherwise browsers hold the first copy for a year. Patterns follow `aws s3 sync` filter rules: `sw.js` matches only the file at the root of `BUILD_FOLDER`, `*.html` matches at any depth.
- `PUBLIC_ACL: true` applies `public-read`; anything else stays private. May fail under account or bucket public-ACL blocks — prefer a bucket policy plus CloudFront OAC.

## License

MIT

[ci-badge]: https://github.com/heronlabs/action-s3-publish/actions/workflows/continuous-integration.yml/badge.svg
[ci-url]: https://github.com/heronlabs/action-s3-publish/actions/workflows/continuous-integration.yml
[license-badge]: https://img.shields.io/badge/License-MIT-blue.svg
[license-url]: ./LICENSE
[marketplace-badge]: https://img.shields.io/badge/GitHub-Marketplace-green.svg
[marketplace-url]: https://github.com/marketplace/actions/action-s3-publish
