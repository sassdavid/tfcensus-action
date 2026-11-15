#!/usr/bin/env bash
# Moves the major tag (v1) to the commit of the published release TAG (vX.Y.Z). It moves only
# when that release is immutable, not a prerelease, and the highest published one of its major.
# The major tag never gets a release of its own: one would make it immutable. Needs GH_TOKEN,
# GITHUB_REPOSITORY and TAG. major-tag.yml runs it when the owner publishes a release.
set -euo pipefail

repo=${GITHUB_REPOSITORY:?}
tag=${TAG:?}
tag=${tag//$'\n'/ }

if [[ ! "$tag" =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::$tag isn't a vX.Y.Z release tag" >&2
  exit 1
fi
major=v${BASH_REMATCH[1]}

release=$(gh api "repos/$repo/releases/tags/$tag" \
  -q '[.draft, .prerelease, (.immutable // false)] | map(tostring) | join(" ")')
read -r draft prerelease immutable <<<"$release"
if [[ "$draft" == true || "$prerelease" == true ]]; then
  echo "::error::$tag is a draft or a prerelease; $major stays where it is" >&2
  exit 1
fi
if [[ "$immutable" != true ]]; then
  echo "::error::$tag isn't immutable; turn on release immutability in the repository settings" >&2
  exit 1
fi
if gh api "repos/$repo/releases/tags/$major" >/dev/null 2>&1; then
  echo "::error::$major has a release; delete it, the major tag must stay movable" >&2
  exit 1
fi

highest=$(gh api --paginate "repos/$repo/releases" \
  -q '.[] | select((.draft or .prerelease) | not) | .tag_name' |
  grep -E "^$major\.[0-9]+\.[0-9]+$" | sort -V | tail -n 1)
if [[ "$highest" != "$tag" ]]; then
  echo "::notice::$tag isn't the highest $major release ($highest is); $major stays where it is"
  exit 0
fi

sha=$(gh api "repos/$repo/commits/$tag" -q .sha)
if gh api "repos/$repo/git/ref/tags/$major" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$repo/git/refs/tags/$major" -f sha="$sha" -F force=true >/dev/null
else
  gh api -X POST "repos/$repo/git/refs" -f ref="refs/tags/$major" -f sha="$sha" >/dev/null
fi
echo "$major now points at $sha ($tag)"
