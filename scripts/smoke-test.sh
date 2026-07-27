#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform -chdir="${repo_dir}/infra/local/application" workspace select dev >/dev/null
base_url="$(terraform -chdir="${repo_dir}/infra/local/application" output -raw floci_invoke_url)"
search_bucket="$(terraform -chdir="${repo_dir}/infra/local/application" output -raw search_results_bucket)"
search_table="$(terraform -chdir="${repo_dir}/infra/local/application" output -raw search_jobs_table)"
file_bucket="$(terraform -chdir="${repo_dir}/infra/local/application" output -raw file_ingest_bucket)"
file_table="$(terraform -chdir="${repo_dir}/infra/local/application" output -raw file_jobs_table)"
token="${FLOCI_TEST_TOKEN:-local:user-001}"
frontend_origin="${FRONTEND_ORIGIN:-http://localhost:4200}"

echo "Checking cross-origin preflight..."
preflight_headers="$(mktemp)"
search_result="$(mktemp)"
download_headers="$(mktemp)"
file_report="$(mktemp)"
upload_headers="$(mktemp)"
trap 'rm -f "${preflight_headers}" "${search_result}" "${download_headers}" "${file_report}" "${upload_headers}"' EXIT
preflight_status="$(curl --silent --output /dev/null --dump-header "${preflight_headers}" \
  --write-out '%{http_code}' -X OPTIONS \
  -H "Origin: ${frontend_origin}" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Authorization" \
  "${base_url}/api/hello")"
if [[ "${preflight_status}" != "200" && "${preflight_status}" != "204" ]]; then
  echo "Expected CORS preflight 200 or 204, got ${preflight_status}" >&2
  exit 1
fi
if ! tr -d '\r' < "${preflight_headers}" |
  grep -qi "^Access-Control-Allow-Origin: ${frontend_origin}$"; then
  echo "CORS preflight did not allow ${frontend_origin}" >&2
  exit 1
fi
echo "Preflight returned ${preflight_status} and allowed ${frontend_origin}."

echo "Checking authorized request..."
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${token}" \
  "${base_url}/api/hello"
echo

echo "Checking individually assigned user..."
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer local:user-003" \
  "${base_url}/api/hello"
echo

echo "Checking authenticated user without hello access..."
status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer local:user-002" \
  "${base_url}/api/hello")"
if [[ "${status}" != "403" ]]; then
  echo "Expected 403, got ${status}" >&2
  exit 1
fi
echo "Unauthorized user returned ${status}."

echo "Checking denied request..."
status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer invalid" \
  "${base_url}/api/hello")"
if [[ "${status}" != "401" && "${status}" != "403" ]]; then
  echo "Expected 401 or 403, got ${status}" >&2
  exit 1
fi
echo "Denied request returned ${status}."

echo "Checking asynchronous search job..."
start_response="$(curl --fail-with-body --silent --show-error \
  -X POST \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  --data '{"query":"engineering","maxResults":25}' \
  "${base_url}/api/search-jobs")"
job_id="$(printf '%s' "${start_response}" | jq -er '.jobId')"

search_status=""
search_response=""
for _ in {1..30}; do
  search_response="$(curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    "${base_url}/api/search-jobs/${job_id}")"
  search_status="$(printf '%s' "${search_response}" | jq -er '.status')"
  if [[ "${search_status}" == "COMPLETED" || "${search_status}" == "FAILED" ]]; then
    break
  fi
  sleep 1
done
if [[ "${search_status}" != "COMPLETED" ]]; then
  echo "Expected asynchronous search to complete, got ${search_status}" >&2
  printf '%s\n' "${search_response}" >&2
  exit 1
fi

download_url="$(printf '%s' "${search_response}" | jq -er '.downloadUrl')"
if [[ "${download_url}" != http://localhost:4566/* || "${download_url}" != *"X-Amz-Expires=300"* ]]; then
  echo "Expected a five-minute Floci pre-signed URL, got ${download_url}" >&2
  exit 1
fi
curl --fail-with-body --silent --show-error \
  --dump-header "${download_headers}" \
  --output "${search_result}" \
  "${download_url}"
if [[ "$(head -n 1 "${search_result}")" != "employeeId,name,department,location,email" ]]; then
  echo "Downloaded search result is not the expected CSV." >&2
  exit 1
fi
if ! grep -q ',engineering,' "${search_result}"; then
  echo "Downloaded search result did not contain the requested records." >&2
  exit 1
fi
if ! tr -d '\r' < "${download_headers}" |
  grep -qi "^Content-Disposition: attachment; filename=\"search-${job_id}.csv\"$"; then
  echo "Downloaded search result did not have the expected attachment header." >&2
  exit 1
fi
echo "Search job ${job_id} completed and its pre-signed URL returned a CSV."

echo "Checking search job ownership..."
status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer local:user-003" \
  "${base_url}/api/search-jobs/${job_id}")"
if [[ "${status}" != "404" ]]; then
  echo "Expected another authorized user to receive 404, got ${status}" >&2
  exit 1
fi
echo "Another user could not read the search job."

echo "Checking application-enforced job expiration..."
expired_at="$(($(date +%s) - 1))"
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-northeast-1 \
  aws --endpoint-url http://localhost:4566 dynamodb update-item \
  --table-name "${search_table}" \
  --key "{\"jobId\":{\"S\":\"${job_id}\"}}" \
  --update-expression "SET expiresAt = :expiresAt" \
  --expression-attribute-values "{\":expiresAt\":{\"N\":\"${expired_at}\"}}" \
  >/dev/null
status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  "${base_url}/api/search-jobs/${job_id}")"
if [[ "${status}" != "410" && "${status}" != "404" ]]; then
  echo "Expected expired search job to receive 410 or TTL-deleted 404, got ${status}" >&2
  exit 1
fi
echo "Expired search job was unavailable with ${status}."

echo "Checking search authorization..."
status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer local:user-002" \
  -H "Content-Type: application/json" \
  --data '{"query":"engineering"}' \
  "${base_url}/api/search-jobs")"
if [[ "${status}" != "403" ]]; then
  echo "Expected user without search access to receive 403, got ${status}" >&2
  exit 1
fi
echo "User without search permission received ${status}."

echo "Checking temporary data retention settings..."
lifecycle="$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-northeast-1 \
  aws --endpoint-url http://localhost:4566 s3api get-bucket-lifecycle-configuration \
  --bucket "${search_bucket}")"
if ! printf '%s' "${lifecycle}" | jq -e \
  '.Rules[] | select(.ID == "expire-temporary-search-results" and .Status == "Enabled" and .Expiration.Days == 1)' \
  >/dev/null; then
  echo "Expected the one-day S3 expiration rule to be enabled." >&2
  exit 1
fi

ttl="$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-northeast-1 \
  aws --endpoint-url http://localhost:4566 dynamodb describe-time-to-live \
  --table-name "${search_table}")"
if ! printf '%s' "${ttl}" | jq -e \
  '.TimeToLiveDescription | select(.TimeToLiveStatus == "ENABLED" and .AttributeName == "expiresAt")' \
  >/dev/null; then
  echo "Expected DynamoDB TTL to be enabled." >&2
  exit 1
fi
echo "S3 one-day expiration and DynamoDB TTL are enabled."

echo "Checking direct CSV upload and S3 event processing..."
file_start="$(curl --fail-with-body --silent --show-error \
  -X POST \
  -H "Authorization: Bearer ${token}" \
  -H "Content-Type: application/json" \
  --data '{"fileName":"employees.csv"}' \
  "${base_url}/api/file-jobs")"
file_job_id="$(printf '%s' "${file_start}" | jq -er '.jobId')"
upload_url="$(printf '%s' "${file_start}" | jq -er '.uploadUrl')"
if [[ "${upload_url}" != http://localhost:4566/* || "${upload_url}" != *"X-Amz-Expires=300"* ]]; then
  echo "Expected a five-minute Floci upload URL, got ${upload_url}" >&2
  exit 1
fi

upload_preflight_status="$(curl --silent --output /dev/null --dump-header "${upload_headers}" \
  --write-out '%{http_code}' -X OPTIONS \
  -H "Origin: ${frontend_origin}" \
  -H "Access-Control-Request-Method: PUT" \
  -H "Access-Control-Request-Headers: content-type" \
  "${upload_url}")"
if [[ "${upload_preflight_status}" != "200" && "${upload_preflight_status}" != "204" ]]; then
  echo "Expected S3 upload preflight 200 or 204, got ${upload_preflight_status}" >&2
  exit 1
fi
if ! tr -d '\r' < "${upload_headers}" |
  grep -qi "^Access-Control-Allow-Origin: ${frontend_origin}$"; then
  echo "S3 upload preflight did not allow ${frontend_origin}" >&2
  exit 1
fi

curl --fail-with-body --silent --show-error \
  -X PUT \
  -H "Origin: ${frontend_origin}" \
  -H "Content-Type: text/csv" \
  --data-binary $'employeeId,name,department\n1,Alice,engineering\n2,Bob,sales\n3,Carol,operations\n' \
  "${upload_url}"

file_state=""
file_response=""
for _ in {1..30}; do
  file_response="$(curl --fail-with-body --silent --show-error \
    -H "Authorization: Bearer ${token}" \
    "${base_url}/api/file-jobs/${file_job_id}")"
  file_state="$(printf '%s' "${file_response}" | jq -er '.status')"
  if [[ "${file_state}" == "COMPLETED" || "${file_state}" == "FAILED" ]]; then
    break
  fi
  sleep 1
done
if [[ "${file_state}" != "COMPLETED" ]]; then
  echo "Expected file ingest to complete, got ${file_state}" >&2
  printf '%s\n' "${file_response}" >&2
  exit 1
fi
if ! printf '%s' "${file_response}" | jq -e \
  '.rowCount == 3 and .columnCount == 3 and .columns == ["employeeId", "name", "department"]' \
  >/dev/null; then
  echo "File ingest summary was not the expected 3-row, 3-column result." >&2
  exit 1
fi

report_url="$(printf '%s' "${file_response}" | jq -er '.reportUrl')"
curl --fail-with-body --silent --show-error --output "${file_report}" "${report_url}"
if ! jq -e \
  '.RowCount == 3 and .ColumnCount == 3 and .Columns == ["employeeId", "name", "department"]' \
  "${file_report}" >/dev/null; then
  echo "Downloaded file processing report was not valid." >&2
  exit 1
fi
echo "File job ${file_job_id} completed through S3 Event -> SQS -> Lambda."

echo "Checking file job ownership and authorization..."
other_file_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Authorization: Bearer local:user-003" \
  "${base_url}/api/file-jobs/${file_job_id}")"
if [[ "${other_file_status}" != "404" ]]; then
  echo "Expected another user to receive 404 for the file job, got ${other_file_status}" >&2
  exit 1
fi
denied_file_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer local:user-002" \
  -H "Content-Type: application/json" \
  --data '{"fileName":"denied.csv"}' \
  "${base_url}/api/file-jobs")"
if [[ "${denied_file_status}" != "403" ]]; then
  echo "Expected user without file ingest access to receive 403, got ${denied_file_status}" >&2
  exit 1
fi

echo "Checking file ingest retention settings..."
file_lifecycle="$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-northeast-1 \
  aws --endpoint-url http://localhost:4566 s3api get-bucket-lifecycle-configuration \
  --bucket "${file_bucket}")"
if ! printf '%s' "${file_lifecycle}" | jq -e \
  '.Rules[] | select(.ID == "expire-temporary-file-ingest-data" and .Status == "Enabled" and .Expiration.Days == 1)' \
  >/dev/null; then
  echo "Expected the one-day file ingest S3 expiration rule to be enabled." >&2
  exit 1
fi
file_ttl="$(AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=ap-northeast-1 \
  aws --endpoint-url http://localhost:4566 dynamodb describe-time-to-live \
  --table-name "${file_table}")"
if ! printf '%s' "${file_ttl}" | jq -e \
  '.TimeToLiveDescription | select(.TimeToLiveStatus == "ENABLED" and .AttributeName == "expiresAt")' \
  >/dev/null; then
  echo "Expected file job DynamoDB TTL to be enabled." >&2
  exit 1
fi
echo "File ingest S3 one-day expiration and DynamoDB TTL are enabled."
