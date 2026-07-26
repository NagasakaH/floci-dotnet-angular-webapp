terraform {
  # Supply bucket, key and region with -backend-config during init.
  # This keeps AWS backend details and credentials out of local development.
  backend "s3" {}
}

