#!/bin/bash

ACL="private";

if [ "$PUBLIC_ACL" == "true" ]; then
  ACL="public-read"
fi

aws s3 rm s3://${BUCKET_NAME} \
  --recursive

aws s3 sync ./${BUILD_FOLDER} s3://${BUCKET_NAME} \
  --storage-class=INTELLIGENT_TIERING \
  --acl $ACL
