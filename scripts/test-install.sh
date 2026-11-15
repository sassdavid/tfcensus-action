#!/usr/bin/env bash
# Tests scripts/install.sh against the real release of the pinned version: each verify mode
# installs a binary that runs, a tampered archive fails every mode, and a tampered archive with a
# rewritten checksums.txt fails attestation and cosign. Needs network access, gh logged in (or
# GH_TOKEN), and cosign or mise. mise run test runs it; so does CI on every OS.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool.env
source "$here/tool.env"

# Keep the expected failures out of the step's annotations, outputs and PATH.
unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_PATH

version=$TOOL_VERSION
case "$(uname -s)" in
  Linux) os=linux ext=tar.gz ;;
  Darwin) os=darwin ext=tar.gz ;;
  *) os=windows ext=zip ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  *) arch=arm64 ;;
esac
archive=${TOOL_NAME}_${version}_${os}_${arch}.$ext

temp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
if command -v cygpath >/dev/null 2>&1; then
  temp=$(cygpath -u "$temp")
fi
work=$(mktemp -d "${temp%/}/$TOOL_NAME-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# expect <name> <exit code> <stderr pattern> [VAR=value...]: runs install.sh with the variables.
expect() {
  local name=$1 want=$2 pattern=$3 got=0
  shift 3
  env RUNNER_TEMP="$work" "$@" bash "$here/install.sh" >"$work/stdout" 2>"$work/stderr" || got=$?
  if [[ "$got" -ne "$want" ]]; then
    fail "$name: exit $got, want $want"
    sed 's/^/    /' "$work/stderr"
  elif ! grep -Eq -- "$pattern" "$work/stderr"; then
    fail "$name: stderr doesn't match /$pattern/"
    sed 's/^/    /' "$work/stderr"
  else
    pass "$name"
  fi
}

# installed <name>: the last install printed a path to a binary that runs.
installed() {
  local path
  path=$(sed -n 's/^path=//p' "$work/stdout")
  if [[ -n "$path" ]] && "$path" version >/dev/null 2>&1; then
    pass "$1 runs $path"
  else
    fail "$1: no runnable binary (path=$path)"
  fi
}

for verify in attestation cosign checksum; do
  expect "install $version, verify=$verify" 0 "sha256 matches" VERIFY="$verify"
  installed "verify=$verify"
done
expect "version latest" 0 "sha256 matches" VERSION=latest VERIFY=checksum
expect "version with v" 0 "$TOOL_NAME $version " VERSION="v$version" VERIFY=checksum
expect "unknown verify" 2 "verify must be" VERIFY=none
expect "bad version" 2 "version must be" VERSION=1.2
expect "path in version" 2 "version must be" VERSION=../../1.0.0

real=$work/real
mkdir "$real"
for f in checksums.txt checksums.txt.sigstore.json "$archive"; do
  curl -fsSL --retry 3 -o "$real/$f" "https://github.com/$TOOL_REPO/releases/download/v$version/$f"
done

# The archive changes, checksums.txt doesn't: every mode stops at sha256.
tampered=$work/tampered
cp -R "$real" "$tampered"
printf 'x' >>"$tampered/$archive"
for verify in attestation cosign checksum; do
  expect "tampered archive, verify=$verify" 1 "sha256 mismatch" VERIFY="$verify" ACTION_TEST_DOWNLOAD_DIR="$tampered"
done

# The attacker also rewrites checksums.txt: sha256 passes, the signature checks don't.
rewritten=$work/rewritten
cp -R "$tampered" "$rewritten"
sum=$(sha256sum "$rewritten/$archive" 2>/dev/null || shasum -a 256 "$rewritten/$archive")
sum=${sum%% *}
awk -v f="$archive" -v s="$sum" '$2 == f { $1 = s; print $1 "  " $2; next } { print }' \
  "$real/checksums.txt" >"$rewritten/checksums.txt"
expect "rewritten checksums, verify=attestation" 1 "attestation verify failed" \
  VERIFY=attestation ACTION_TEST_DOWNLOAD_DIR="$rewritten"
expect "rewritten checksums, verify=cosign" 1 "cosign verify-blob failed" \
  VERIFY=cosign ACTION_TEST_DOWNLOAD_DIR="$rewritten"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all install tests passed"
