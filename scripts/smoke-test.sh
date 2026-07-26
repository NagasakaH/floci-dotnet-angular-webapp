#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform -chdir="${repo_dir}/infra/local/application" workspace select dev >/dev/null
base_url="$(terraform -chdir="${repo_dir}/infra/local/application" output -raw floci_invoke_url)"
token="${FLOCI_TEST_TOKEN:-local:user-001}"
frontend_origin="${FRONTEND_ORIGIN:-http://localhost:4200}"

echo "Checking cross-origin preflight..."
preflight_headers="$(mktemp)"
trap 'rm -f "${preflight_headers}"' EXIT
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
