#!/usr/bin/env bash
# The action's entry point: checks MODE, installs the tool with scripts/install.sh, then runs
# the mode. Only install exists so far; report and comment come with M14's next items.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool.env
source "$here/tool.env"

mode=${MODE:-install}
case "$mode" in
  install) ;;
  *)
    msg="mode must be install, not \"${mode//$'\n'/ }\""
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
      echo "::error title=$TOOL_NAME action::$msg" >&2
    else
      echo "$TOOL_NAME action: $msg" >&2
    fi
    exit 2
    ;;
esac

bash "$here/install.sh"
