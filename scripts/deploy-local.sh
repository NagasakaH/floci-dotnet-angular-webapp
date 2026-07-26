#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${repo_dir}/scripts/build-lambdas.sh"

docker compose -f "${repo_dir}/compose.yaml" up -d --wait
terraform -chdir="${repo_dir}/infra/environments/local" init
terraform -chdir="${repo_dir}/infra/environments/local" apply -auto-approve

terraform -chdir="${repo_dir}/infra/environments/local" output -raw floci_invoke_url
echo
