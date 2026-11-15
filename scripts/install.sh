#!/usr/bin/env bash
# Downloads a release of the tool in tool.env, checks it and puts the binary on PATH.
#
# Every download is checked against checksums.txt (sha256). VERIFY adds one more check:
#   attestation  gh attestation verify on the archive, pinned to the release workflow (default)
#   cosign       cosign verify-blob on checksums.txt with the release's sigstore bundle
#   checksum     nothing more
#
# Environment: VERSION (empty for the pin in tool.env, X.Y.Z, vX.Y.Z or latest), VERIFY,
# GH_TOKEN (for gh). ACTION_TEST_DOWNLOAD_DIR replaces the download with a local directory and
# is for scripts/test-install.sh only. Writes the version and path outputs when GITHUB_OUTPUT is
# set. Exits 2 on a bad input and 1 when a download or a check fails.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool.env
source "$here/tool.env"

# renovate: datasource=github-releases depName=sigstore/cosign
COSIGN_VERSION=3.1.4
OIDC_ISSUER=https://token.actions.githubusercontent.com

die() {
  local code=$1 msg=${2//$'\n'/ }
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error title=$TOOL_NAME install::$msg" >&2
  else
    echo "$TOOL_NAME install: $msg" >&2
  fi
  exit "$code"
}
log() { echo "$TOOL_NAME install: $*" >&2; }

# native prints a path in the form the runner expects in GITHUB_PATH and GITHUB_OUTPUT.
native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

verify=${VERIFY:-attestation}
case "$verify" in
  attestation | cosign | checksum) ;;
  *) die 2 "verify must be attestation, cosign or checksum, not \"$verify\"" ;;
esac

version=${VERSION:-$TOOL_VERSION}
version=${version#v}
if [[ "$version" == latest ]]; then
  url=$(curl -fsSI --proto '=https' --tlsv1.2 --retry 3 -o /dev/null -w '%{redirect_url}' \
    "https://github.com/$TOOL_REPO/releases/latest") || die 1 "can't resolve the latest release of $TOOL_REPO"
  version=${url##*/tag/v}
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die 2 "version must be X.Y.Z, vX.Y.Z or latest, not \"$version\""
fi

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT) os=windows ;;
  *) die 1 "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) die 1 "unsupported architecture $(uname -m)" ;;
esac
ext=tar.gz exe=$TOOL_NAME
if [[ "$os" == windows ]]; then
  ext=zip exe=$TOOL_NAME.exe
fi
archive=${TOOL_NAME}_${version}_${os}_${arch}.$ext

temp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
if command -v cygpath >/dev/null 2>&1; then
  temp=$(cygpath -u "$temp")
fi
work=$(mktemp -d "${temp%/}/$TOOL_NAME-install.XXXXXX")
dl=$work/download
out=$work/extract
mkdir "$dl" "$out"

fetch() {
  if [[ -n "${ACTION_TEST_DOWNLOAD_DIR:-}" ]]; then
    cp "$ACTION_TEST_DOWNLOAD_DIR/$1" "$dl/$1" || die 1 "$1 not found in $ACTION_TEST_DOWNLOAD_DIR"
    return
  fi
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$dl/$1" \
    "https://github.com/$TOOL_REPO/releases/download/v$version/$1" || die 1 "can't download $1 of $TOOL_REPO v$version"
}

log "$TOOL_NAME $version ($os/$arch), verify=$verify"
fetch checksums.txt
fetch "$archive"

want=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$dl/checksums.txt")
[[ -n "$want" ]] || die 1 "checksums.txt has no line for $archive"
got=$(sha256 "$dl/$archive")
[[ "$got" == "$want" ]] || die 1 "sha256 mismatch for $archive: got $got, checksums.txt has $want"
log "sha256 matches checksums.txt"

case "$verify" in
  attestation)
    command -v gh >/dev/null 2>&1 || die 1 "verify: attestation needs the gh CLI; install it or use verify: cosign"
    gh attestation verify "$dl/$archive" --repo "$TOOL_REPO" \
      --signer-workflow "$TOOL_SIGNER_WORKFLOW" --deny-self-hosted-runners >&2 ||
      die 1 "gh attestation verify failed for $archive (signer workflow $TOOL_SIGNER_WORKFLOW)"
    ;;
  cosign)
    if command -v cosign >/dev/null 2>&1; then
      cosign=(cosign)
    elif command -v mise >/dev/null 2>&1; then
      # mise exec doesn't install when auto-install is off, so install first. mise checks the
      # download. Run from the work directory so mise reads no project config.
      (cd "$work" && mise install "aqua:sigstore/cosign@$COSIGN_VERSION" >&2) ||
        die 1 "mise can't install cosign $COSIGN_VERSION"
      cosign=(mise exec "aqua:sigstore/cosign@$COSIGN_VERSION" -- cosign)
    else
      die 1 "verify: cosign needs cosign or mise on PATH; add cosign to your mise.toml, or use verify: attestation"
    fi
    fetch checksums.txt.sigstore.json
    identity="^https://github\\.com/${TOOL_SIGNER_WORKFLOW//./\\.}@refs/"
    (cd "$work" && "${cosign[@]}" verify-blob --bundle "$dl/checksums.txt.sigstore.json" \
      --certificate-identity-regexp "$identity" --certificate-oidc-issuer "$OIDC_ISSUER" \
      "$dl/checksums.txt" >&2) || die 1 "cosign verify-blob failed for checksums.txt (identity $identity)"
    ;;
esac

if [[ "$ext" == zip ]]; then
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$dl/$archive" "$exe" -d "$out"
  else
    pwsh -NoProfile -Command "Expand-Archive -LiteralPath '$(native "$dl/$archive")' -DestinationPath '$(native "$out")'"
  fi
else
  tar -xzf "$dl/$archive" -C "$out" "$exe"
fi
[[ -f "$out/$exe" ]] || die 1 "$archive has no $exe"

bin=$work/bin
mkdir "$bin"
mv "$out/$exe" "$bin/$exe"
chmod +x "$bin/$exe"
rm -rf "$dl" "$out"
"$bin/$exe" version >&2 || die 1 "$exe doesn't run"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  native "$bin" >>"$GITHUB_PATH"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$version"
    echo "path=$(native "$bin/$exe")"
  } >>"$GITHUB_OUTPUT"
else
  echo "version=$version"
  echo "path=$bin/$exe"
fi
