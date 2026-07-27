#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
foundation_dir="${repo_dir}/infra/aws/foundation"
application_dir="${repo_dir}/infra/aws/application"

if [[ "$(terraform -chdir="${foundation_dir}" workspace show)" != "dev" ]]; then
  echo "AWS foundation workspace must be dev." >&2
  exit 1
fi
if [[ "$(terraform -chdir="${application_dir}" workspace show)" != "dev" ]]; then
  echo "AWS application workspace must be dev." >&2
  exit 1
fi

api_base_url="$(terraform -chdir="${application_dir}" output -raw api_invoke_url)"
frontend_bucket="$(terraform -chdir="${foundation_dir}" output -raw frontend_bucket_name)"
distribution_id="$(terraform -chdir="${foundation_dir}" output -raw cloudfront_distribution_id)"
frontend_url="$(terraform -chdir="${foundation_dir}" output -raw frontend_url)"

cd "${repo_dir}/frontend"
npm run build

dist_dir="${repo_dir}/frontend/dist/frontend/browser"
node -e '
const fs = require("node:fs");
fs.writeFileSync(
  process.argv[1],
  `${JSON.stringify({ apiBaseUrl: process.argv[2] }, null, 2)}\n`,
);
' "${dist_dir}/config.json" "${api_base_url}"

aws s3 sync "${dist_dir}" "s3://${frontend_bucket}" \
  --delete \
  --cache-control "public,max-age=300"
aws s3 cp "${dist_dir}/index.html" "s3://${frontend_bucket}/index.html" \
  --content-type "text/html" \
  --cache-control "no-cache,no-store,must-revalidate"
aws s3 cp "${dist_dir}/config.json" "s3://${frontend_bucket}/config.json" \
  --content-type "application/json" \
  --cache-control "no-cache,no-store,must-revalidate"

invalidation_id="$(
  aws cloudfront create-invalidation \
    --distribution-id "${distribution_id}" \
    --paths "/*" \
    --query "Invalidation.Id" \
    --output text
)"

echo "Frontend URL: ${frontend_url}"
echo "CloudFront invalidation: ${invalidation_id}"
