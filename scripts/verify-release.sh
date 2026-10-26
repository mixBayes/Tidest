#!/usr/bin/env bash
set -euo pipefail

tag="${1:?Usage: verify-release.sh vX.Y.Z ASSET_DIRECTORY}"
asset_dir="${2:?Usage: verify-release.sh vX.Y.Z ASSET_DIRECTORY}"
repo="${GITHUB_REPOSITORY:?Set GITHUB_REPOSITORY to the release repository}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid release tag: $tag" >&2
  exit 1
}

# Resolve both identities from the checked-out repository, not the downloaded files.
tag_digest="$(git rev-parse --verify "refs/tags/$tag")"
source_commit="$(git rev-parse --verify "refs/tags/$tag^{commit}")"
asset_dir="$(cd "$asset_dir" && pwd)"
published="$(gh api "repos/$repo/releases/tags/$tag" \
  --jq '.immutable == true and .draft == false')"
[[ "$published" == true ]] || {
  echo "$tag must be a published immutable release." >&2
  exit 1
}
response_dir="$(mktemp -d)"
trap 'rm -rf "$response_dir"' EXIT

# Publication and generation of GitHub's release proof are asynchronous. Query
# readiness separately: gh release verify can hide API errors as "no attestations".
for ((attempt = 1; attempt <= 13; attempt++)); do
  if gh api --include "repos/$repo/attestations/sha1:$tag_digest?predicate_type=release" \
    >"$response_dir/response" 2>"$response_dir/error"; then
    proof_count="$(awk 'body {print} /^\r?$/ {body = 1}' "$response_dir/response" | \
      jq -er '.attestations | if type == "array" then length else error("Invalid attestation response") end')"
  else
    api_exit=$?
    # GitHub returns 404 while this proof does not exist. The release itself was
    # checked above; authentication, rate limits, server and network errors fail.
    if read -r protocol http_status status_text <"$response_dir/response" && [[ "$http_status" == 404 ]]; then
      proof_count=0
    else
      cat "$response_dir/error" >&2
      exit "$api_exit"
    fi
  fi
  if ((proof_count > 0)); then
    break
  fi
  if ((attempt == 13)); then
    echo "GitHub has not generated the release proof for $tag after 120 seconds. Run Verify release again later." >&2
    exit 1
  fi
  echo "Waiting for GitHub to generate the release proof for $tag ($attempt/12)."
  sleep 10
done

gh release verify "$tag" -R "$repo"
cd "$asset_dir"
for asset in "Tidest-${tag#v}.dmg" BUILD-INFO.json SHA256SUMS provenance.sigstore.json; do
  gh release verify-asset "$tag" "$asset" -R "$repo"
done
shasum -a 256 -c SHA256SUMS
for asset in "Tidest-${tag#v}.dmg" BUILD-INFO.json SHA256SUMS; do
  gh attestation verify "$asset" -R "$repo" \
    --bundle provenance.sigstore.json \
    --signer-workflow "$repo/.github/workflows/release.yml" \
    --source-ref "refs/tags/$tag" --source-digest "$source_commit" \
    --deny-self-hosted-runners
done
jq -e --arg tag "$tag" --arg commit "$source_commit" --arg repo "$repo" \
  '.tag == $tag and .version == ($tag | ltrimstr("v")) and .commit == $commit and .repository == $repo' \
  BUILD-INFO.json >/dev/null
echo "Verified $tag: all four release assets and their source commit $source_commit."
