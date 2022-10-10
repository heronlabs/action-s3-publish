aws s3 sync ./${BUILD_FOLDER} s3://${BUCKET_NAME} \
  --storage-class=INTELLIGENT_TIERING