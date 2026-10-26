#!/usr/bin/env bash
# Called only by the job that depends on successful release verification.
set -euo pipefail

tag="${1:?Usage: sync-release-deployment.sh vX.Y.Z VERIFIED_COMMIT}"
commit="${2:?Usage: sync-release-deployment.sh vX.Y.Z VERIFIED_COMMIT}"
repo="${GITHUB_REPOSITORY:?Missing release repository}"
run_id="${GITHUB_RUN_ID:?Missing verification run ID}"
attempt="${GITHUB_RUN_ATTEMPT:?Missing verification attempt}"
summary_path="${GITHUB_STEP_SUMMARY:?Missing job summary path}"
[[ "${GITHUB_REF:-}" == refs/heads/main ]] || {
  echo 'Run deployment status updates from main.' >&2
  exit 1
}
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'A version tag and a verified source commit are required.' >&2
  exit 1
}
[[ "$run_id" =~ ^[0-9]+$ && "$attempt" =~ ^[0-9]+$ ]] || {
  echo 'A valid verification run and attempt are required.' >&2
  exit 1
}

# Match all three fields rather than changing the latest deployment by position.
deployments="$(gh api --method GET "repos/$repo/deployments" --paginate \
  -f ref="$tag" -f sha="$commit" -f environment=release)"
deployment_id="$(jq -ers --arg tag "$tag" --arg commit "$commit" '
  add | map(select(.ref == $tag and .sha == $commit and .environment == "release")) |
  if length == 1 then .[0].id else error("Expected exactly one matching release deployment; no status was changed.") end
' <<< "$deployments")"
[[ "$deployment_id" =~ ^[0-9]+$ ]]

log_url="https://github.com/$repo/actions/runs/$run_id/attempts/$attempt"
release_url="https://github.com/$repo/releases/tag/$tag"
status="$(gh api --method POST "repos/$repo/deployments/$deployment_id/statuses" \
  -f state=success \
  -f description='Release assets, source provenance and Apple notarization verified.' \
  -f log_url="$log_url" -f environment_url="$release_url" \
  -F auto_inactive=false)"
jq -e --arg url "https://api.github.com/repos/$repo/deployments/$deployment_id" \
  --arg log_url "$log_url" \
  '.state == "success" and .deployment_url == $url and .log_url == $log_url' \
  <<< "$status" >/dev/null

echo "Updated release deployment $deployment_id for $tag to success after verification."
echo "Updated the existing [release deployment](https://github.com/$repo/deployments/release) for [$tag]($release_url) to success. [Verification run]($log_url). Original workflow history is retained." >> "$summary_path"
