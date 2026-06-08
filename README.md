# Publish S3 Action

A GitHub Action that publishes a local build folder to an S3 bucket, typically for static-site hosting.

The action first **empties the destination bucket** via `aws s3 rm --recursive`, then uploads everything under `BUILD_FOLDER` with `Cache-Control: max-age=31536000,public` and `INTELLIGENT_TIERING` storage class. Authentication is OIDC-only.

## Requirements

### Permissions

```yaml
permissions:
  id-token: write
  contents: read
```

### AWS IAM Role

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

### Supported Runners

- `ubuntu-24.04` (recommended)
- `ubuntu-22.04`
- `ubuntu-latest`

### Dependencies

- `aws` CLI (pre-installed on GitHub-hosted runners)
- Internal: `aws-actions/configure-aws-credentials@v6`

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `AWS_ROLE_TO_ASSUME` | ARN of the IAM role to assume via OIDC | Yes | — |
| `AWS_REGION` | AWS region where the S3 bucket lives | Yes | — |
| `AWS_ROLE_DURATION_SECONDS` | Duration in seconds for the assumed role session | Yes | — |
| `BUILD_FOLDER` | Local folder whose contents should be published | Yes | — |
| `BUCKET_NAME` | Destination S3 bucket name | Yes | — |
| `PUBLIC_ACL` | Set to `"true"` to apply `public-read` ACL | No | `private` |

## Outputs

This action does not produce outputs.

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
      - uses: actions/checkout@v6

      - name: Build
        run: npm ci && npm run build

      - name: Publish to S3
        uses: heronlabs/action-s3-publish@v2
        with:
          AWS_ROLE_TO_ASSUME: ${{ secrets.AWS_ROLE_ARN }}
          AWS_REGION: us-east-1
          AWS_ROLE_DURATION_SECONDS: 900
          BUILD_FOLDER: dist
          BUCKET_NAME: my-site-bucket
          PUBLIC_ACL: 'true'

      - name: Invalidate CloudFront
        uses: heronlabs/action-cloudfront-publish@v2
        with:
          AWS_ROLE_TO_ASSUME: ${{ secrets.AWS_ROLE_ARN }}
          AWS_REGION: us-east-1
          AWS_ROLE_DURATION_SECONDS: 900
          DISTRIBUTION_ID: E1ABCDEF2GHIJK
```

## Notes

- **Destructive sync**: the step runs `aws s3 rm --recursive` before uploading. Do not point this action at a bucket that also stores non-static files.
- **Long cache headers**: every file receives `max-age=31536000`. Pair with a CloudFront invalidation after each deploy, or use content-hashed filenames.
- **Public ACLs**: many AWS accounts now block public ACLs at the bucket/account level. Prefer a bucket policy + CloudFront origin access control over `PUBLIC_ACL: true`.

## License

MIT
