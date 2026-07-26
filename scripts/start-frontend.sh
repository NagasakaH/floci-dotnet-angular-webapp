#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
api_base_url="$(
  terraform -chdir="${repo_dir}/infra/local/application" output -raw floci_invoke_url
)"

node -e '
const fs = require("node:fs");
fs.writeFileSync(
  process.argv[1],
  `${JSON.stringify({ apiBaseUrl: process.argv[2] }, null, 2)}\n`,
);
' "${repo_dir}/frontend/public/config.json" "${api_base_url}"

echo "Angular API endpoint: ${api_base_url}"
cd "${repo_dir}/frontend"
npm start
