#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${repo_dir}/scripts/build-lambdas.sh"

docker compose -f "${repo_dir}/compose.yaml" up -d --wait
terraform -chdir="${repo_dir}/infra/local/application" init
terraform -chdir="${repo_dir}/infra/local/application" workspace select dev ||
  terraform -chdir="${repo_dir}/infra/local/application" workspace new dev
terraform -chdir="${repo_dir}/infra/local/application" apply -auto-approve

terraform -chdir="${repo_dir}/infra/local/application" output -raw floci_invoke_url
echo
