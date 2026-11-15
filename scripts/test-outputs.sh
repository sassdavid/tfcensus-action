#!/usr/bin/env bash
# Checks what the action left for later steps in CI: the version and path outputs, and the
# binary on PATH. ci.yml passes the outputs as OUT_VERSION and OUT_PATH.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool.env
source "$here/tool.env"

if [[ "${OUT_VERSION:-}" != "$TOOL_VERSION" ]]; then
  echo "version output is \"${OUT_VERSION:-}\", want $TOOL_VERSION" >&2
  exit 1
fi
bin=${OUT_PATH:?path output is empty}
if command -v cygpath >/dev/null 2>&1; then
  bin=$(cygpath -u "$bin")
fi
"$bin" version
on_path=$(command -v "$TOOL_NAME")
echo "$TOOL_NAME on PATH: $on_path"
"$TOOL_NAME" version
