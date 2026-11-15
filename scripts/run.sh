#!/usr/bin/env bash
# The action's entry point: checks the inputs, installs the tool with scripts/install.sh, then
# runs the mode. install stops there. report runs one command that writes JSON and Markdown and,
# for the commands in TOOL_SARIF_COMMANDS, SARIF and annotations. comment does the same, then
# keeps one pull request comment with "notify --notify github-pr-comment". A pull request from a
# fork or from Dependabot gets a read-only token, so it gets the step summary instead.
#
# Environment: the install.sh variables, plus MODE, COMMAND, ARGS (one argument per line), FROM,
# FAIL_ON (separated by commas or newlines), SARIF, STEP_SUMMARY, WORKING_DIRECTORY and HEAD_REPO
# (the pull request's head repository). ACTION_TEST_TOOL replaces the install with a local binary
# and is for scripts/test-run.sh only. Exits 2 on a bad input, 1 when the install fails, and
# otherwise with the command's exit code, or notify's when the command passed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool.env
source "$here/tool.env"

die() {
  local code=$1 msg=${2//$'\n'/ }
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error title=$TOOL_NAME action::$msg" >&2
  else
    echo "$TOOL_NAME action: $msg" >&2
  fi
  exit "$code"
}
notice() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::notice title=$TOOL_NAME action::$1" >&2
  else
    echo "$TOOL_NAME action: $1" >&2
  fi
}

# has <word> <list>: the space-separated list contains the word.
has() {
  local w
  for w in $2; do
    [[ "$w" == "$1" ]] && return 0
  done
  return 1
}

# native prints a path in the form the runner expects in GITHUB_OUTPUT.
native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

# mixed prints a path that both bash and a native Windows binary read (C:/a/b).
mixed() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1=$2" >>"$GITHUB_OUTPUT"
  else
    echo "$1=$2"
  fi
}

boolean() {
  case "$2" in
    true | false) ;;
    *) die 2 "$1 must be true or false, not \"$2\"" ;;
  esac
}

mode=${MODE:-install}
command=${COMMAND:-}
from=${FROM:-}
sarif=${SARIF:-true}
summary=${STEP_SUMMARY:-true}
wd=${WORKING_DIRECTORY:-.}
boolean sarif "$sarif"
boolean step-summary "$summary"

case "$mode" in
  install)
    if [[ -n "$command$from${ARGS:-}${FAIL_ON:-}" ]]; then
      die 2 "command, args, from and fail-on need mode report or comment"
    fi
    ;;
  report | comment)
    if [[ "$mode" == report ]]; then allowed=$TOOL_REPORT_COMMANDS; else allowed=$TOOL_COMMENT_COMMANDS; fi
    command=${command:-${allowed%% *}}
    if ! has "$command" "$allowed"; then
      die 2 "mode $mode takes command ${allowed// / or }, not \"$command\""
    fi
    if [[ -n "$from" && -z "$TOOL_FROM_FLAG" ]]; then
      die 2 "$TOOL_NAME has no input that from sets; pass flags through args"
    fi
    if [[ "$mode" == comment && "${GITHUB_EVENT_NAME:-}" != pull_request ]]; then
      die 2 "mode comment needs a pull_request event, not \"${GITHUB_EVENT_NAME:-}\""
    fi
    [[ -d "$wd" ]] || die 2 "working-directory \"$wd\" is not a directory"
    ;;
  *) die 2 "mode must be install, report or comment, not \"$mode\"" ;;
esac

if [[ -n "${ACTION_TEST_TOOL:-}" ]]; then
  version=$TOOL_VERSION bin=$ACTION_TEST_TOOL
else
  # install.sh prints the outputs instead of writing them when GITHUB_OUTPUT is unset.
  installed=$(
    unset GITHUB_OUTPUT
    bash "$here/install.sh"
  )
  version=$(sed -n 's/^version=//p' <<<"$installed")
  bin=$(sed -n 's/^path=//p' <<<"$installed")
fi
output version "$version"
output path "$(native "$bin")"
[[ "$mode" == install ]] && exit 0

temp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
if command -v cygpath >/dev/null 2>&1; then
  temp=$(cygpath -u "$temp")
fi
dir=$(mktemp -d "${temp%/}/$TOOL_NAME-$command.XXXXXX")
json=$dir/$command.json md=$dir/$command.md sarif_file=

args=()
if [[ "$mode" == comment && -n "$TOOL_COMMENT_FLAGS" ]]; then
  read -r -a args <<<"$TOOL_COMMENT_FLAGS"
fi
if has "$command" "$TOOL_SARIF_COMMANDS"; then
  sarif_file=$dir/$command.sarif
  args+=(--format github --out "sarif=$(mixed "$sarif_file")")
else
  args+=(--format plain)
fi
args+=(--out "json=$(mixed "$json")" --out "md=$(mixed "$md")")

IFS=$', \n\r' read -r -d '' -a gates <<<"${FAIL_ON:-}" || true
for gate in ${gates[@]+"${gates[@]}"}; do
  args+=(--fail-on "$gate")
done

user=()
while IFS= read -r line; do
  line=${line%$'\r'}
  [[ -n "$line" ]] && user+=("$line")
done <<<"${ARGS:-}"

if [[ -n "$from" ]]; then
  args+=("$TOOL_FROM_FLAG" "$from")
  # Skip the file flag when args name it, or when from has no such file.
  named=false
  for a in ${user[@]+"${user[@]}"}; do
    [[ "$a" == "$TOOL_FROM_FILE_FLAG" || "$a" == "$TOOL_FROM_FILE_FLAG="* ]] && named=true
  done
  if [[ -n "$TOOL_FROM_FILE_FLAG" && "$named" == false && -f "$wd/$from/$TOOL_FROM_FILE" ]]; then
    args+=("$TOOL_FROM_FILE_FLAG" "$from/$TOOL_FROM_FILE")
  fi
fi

code=0
(cd "$wd" && "$bin" "$command" "${args[@]}" ${user[@]+"${user[@]}"}) || code=$?
output exit-code "$code"
[[ -s "$json" ]] && output json-file "$(native "$json")"
[[ -s "$md" ]] && output md-file "$(native "$md")"
if [[ -n "$sarif_file" && -s "$sarif_file" ]]; then
  output sarif-file "$(native "$sarif_file")"
  # One category per command and directory, so two runs don't replace each other's alerts. The
  # directory is relative to the workspace; one outside it adds its last element.
  category=$TOOL_NAME-$command
  sub=$(mixed "$wd")
  if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then sub=${sub#"$(mixed "$GITHUB_WORKSPACE")"/}; fi
  sub=${sub#./}
  sub=${sub%/}
  if [[ "$sub" == /* || "$sub" == [A-Za-z]:/* ]]; then sub=${sub##*/}; fi
  if [[ -n "$sub" && "$sub" != . ]]; then category+=/$sub; fi
  output sarif-category "$category"
fi

write_summary() {
  if [[ -s "$md" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$md" >>"$GITHUB_STEP_SUMMARY"
  fi
}
[[ "$summary" == true ]] && write_summary

if [[ "$mode" == comment && -s "$json" ]]; then
  reason=
  if [[ -z "${HEAD_REPO:-}" ]]; then
    reason="the pull request's head repository is unknown"
  elif [[ "$HEAD_REPO" != "${GITHUB_REPOSITORY:-}" ]]; then
    reason="the pull request comes from the fork $HEAD_REPO"
  elif [[ "${GITHUB_ACTOR:-}" == "dependabot[bot]" ]]; then
    reason="Dependabot pull requests get a read-only token"
  fi
  if [[ -n "$reason" ]]; then
    notice "no comment: $reason, so the report is in the step summary"
    [[ "$summary" == true ]] || write_summary
  else
    notify=0
    (cd "$wd" && "$bin" notify --from "$(mixed "$json")" --notify github-pr-comment) || notify=$?
    if [[ "$code" -eq 0 ]]; then code=$notify; fi
  fi
fi

exit "$code"
