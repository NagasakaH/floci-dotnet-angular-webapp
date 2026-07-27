#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts_dir="${repo_dir}/infra/artifacts"
hello_dir="${artifacts_dir}/hello"
authorizer_dir="${artifacts_dir}/authorizer"
search_jobs_dir="${artifacts_dir}/search-jobs"
file_ingest_dir="${artifacts_dir}/file-ingest"

mkdir -p "${hello_dir}" "${authorizer_dir}" "${search_jobs_dir}" "${file_ingest_dir}"
find "${hello_dir}" -mindepth 1 -delete
find "${authorizer_dir}" -mindepth 1 -delete
find "${search_jobs_dir}" -mindepth 1 -delete
find "${file_ingest_dir}" -mindepth 1 -delete

dotnet publish "${repo_dir}/src/HelloApi/HelloApi.csproj" -c Release -o "${hello_dir}" \
  --disable-build-servers -m:1
dotnet publish "${repo_dir}/src/SearchJobs/SearchJobs.csproj" -c Release -o "${search_jobs_dir}" \
  --disable-build-servers -m:1
dotnet publish "${repo_dir}/src/FileIngest/FileIngest.csproj" -c Release -o "${file_ingest_dir}" \
  --disable-build-servers -m:1
(
  cd "${repo_dir}/src/ApiAuthorizer"
  GOCACHE="${repo_dir}/.cache/go-build" \
    GOMODCACHE="${repo_dir}/.cache/go-mod" \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o "${authorizer_dir}/bootstrap" .
)
cp "${repo_dir}/src/ApiAuthorizer/authorization.json" "${authorizer_dir}/authorization.json"

# Stable timestamps keep source_code_hash unchanged when source output is unchanged.
find "${hello_dir}" "${authorizer_dir}" "${search_jobs_dir}" "${file_ingest_dir}" \
  -type f -exec touch -t 198001010000 {} +
(cd "${hello_dir}" && zip -q -FS -r ../hello.zip .)
(cd "${authorizer_dir}" && zip -q -FS -r ../authorizer.zip .)
(cd "${search_jobs_dir}" && zip -q -FS -r ../search-jobs.zip .)
(cd "${file_ingest_dir}" && zip -q -FS -r ../file-ingest.zip .)

echo "Lambda packages created under infra/artifacts."
