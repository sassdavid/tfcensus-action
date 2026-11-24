#!/usr/bin/env bash
# Tests scripts/run.sh offline with a stub binary in place of the install: the input checks, the
# arguments report and comment mode build, the outputs, the step summary, the exit codes, and the
# comment on a pull request from this repository but not from a fork or Dependabot. The stub logs
# its arguments and writes the --out files. mise run test runs it; so does CI on every OS.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool.env
source "$here/tool.env"

# Keep the expected failures out of the step's annotations, outputs and summary, and start each
# case from a clean environment.
unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY GITHUB_EVENT_NAME \
  GITHUB_REPOSITORY GITHUB_ACTOR GITHUB_WORKSPACE HEAD_REPO MODE COMMAND ARGS FROM FAIL_ON \
  SARIF STEP_SUMMARY WORKING_DIRECTORY VERSION VERIFY

temp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
if command -v cygpath >/dev/null 2>&1; then
  temp=$(cygpath -u "$temp")
fi
work=$(mktemp -d "${temp%/}/$TOOL_NAME-test-run.XXXXXX")
trap 'rm -rf "$work"' EXIT

stub=$work/bin/$TOOL_NAME
mkdir "$work/bin"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
# Logs one argument per line to $STUB_LOG.<command>, writes each --out file, exits with
# $STUB_EXIT (the command) or $STUB_NOTIFY_EXIT (notify).
printf '%s\n' "$@" >"$STUB_LOG.$1"
pwd >"$STUB_LOG.$1.pwd"
for a in "$@"; do
  case "$a" in
    json=* | md=* | sarif=*) echo "stub ${a%%=*} for $1" >"${a#*=}" ;;
  esac
done
if [[ "$1" == notify ]]; then exit "${STUB_NOTIFY_EXIT:-0}"; fi
echo "::warning file=mise.toml::stub annotation"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$stub"

failures=0
pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# run <name> <exit code> [VAR=value...]: runs run.sh in a fresh case directory with the stub,
# then checks the exit code. The checks below read $case.
run() {
  local name=$1 want=$2 got=0
  shift 2
  case=$work/case$((++n))
  mkdir -p "$case/repo/sub/dir" "$case/repo/plans"
  if [[ -n "$with_file" ]]; then : >"$case/repo/plans/$with_file"; fi
  : >"$case/output"
  : >"$case/summary"
  (cd "$case/repo" && env RUNNER_TEMP="$case" ACTION_TEST_TOOL="$stub" STUB_LOG="$case/log" \
    GITHUB_OUTPUT="$case/output" GITHUB_STEP_SUMMARY="$case/summary" "$@" \
    bash "$here/run.sh" >"$case/stdout" 2>"$case/stderr") || got=$?
  if [[ "$got" -ne "$want" ]]; then
    fail "$name: exit $got, want $want"
    sed 's/^/    /' "$case/stderr"
    return 1
  fi
  pass "$name"
}
n=0 with_file=

# check <name> <command>: runs the command (a test) and reports it.
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

out() { sed -n "s/^$1=//p" "$case/output"; }
# logged <command> <argument>...: the stub got these consecutive arguments for the command.
logged() {
  local cmd=$1 hay want
  shift
  [[ -f "$case/log.$cmd" ]] || return 1
  hay=$'\036'$(tr '\n' '\036' <"$case/log.$cmd")
  want=$'\036'$(printf '%s\036' "$@")
  [[ "$hay" == *"$want"* ]]
}
stderr_has() { grep -Eq -- "$1" "$case/stderr"; }
# exists <output>: the output names a file that exists (native paths become Unix ones).
exists() {
  local p
  p=$(out "$1")
  [[ -n "$p" ]] || return 1
  if command -v cygpath >/dev/null 2>&1; then p=$(cygpath -u "$p"); fi
  [[ -s "$p" ]]
}

has() { [[ " $2 " == *" $1 "* ]]; }

report=${TOOL_REPORT_COMMANDS%% *}
comment=${TOOL_COMMENT_COMMANDS%% *}
pr=(GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=owner/repo HEAD_REPO=owner/repo GITHUB_ACTOR=someone)

# Inputs that exit 2 before anything runs.
run "unknown mode" 2 MODE=bogus && stderr_has "mode must be install, report or comment"
run "install with a command" 2 COMMAND="$report" && stderr_has "need mode report or comment"
run "install with fail-on" 2 FAIL_ON=x
run "unknown command" 2 MODE=report COMMAND=bogus && stderr_has "mode report takes command"
run "comment command in report mode" 2 MODE=comment COMMAND=bogus "${pr[@]}"
run "bad sarif" 2 MODE=report SARIF=yes && stderr_has "sarif must be true or false"
run "bad step-summary" 2 MODE=report STEP_SUMMARY=1
run "missing working-directory" 2 MODE=report WORKING_DIRECTORY=nope && stderr_has "not a directory"
run "comment on push" 2 MODE=comment GITHUB_EVENT_NAME=push && stderr_has "needs a pull_request event"
check "nothing ran on a bad input" test ! -e "$case/log.$comment"
if [[ -n "$TOOL_COMMENT_MIN_VERSION" ]]; then
  # The highest version below the minimum, with 99 for a part that counts down.
  IFS=. read -r major minor patch <<<"$TOOL_COMMENT_MIN_VERSION"
  if ((patch > 0)); then
    below=$major.$minor.$((patch - 1))
  elif ((minor > 0)); then
    below=$major.$((minor - 1)).99
  else
    below=$((major - 1)).99.99
  fi
  run "comment below the minimum version" 2 MODE=comment VERSION="v$below" "${pr[@]}" &&
    stderr_has "needs $TOOL_NAME $TOOL_COMMENT_MIN_VERSION or later, not $below"
  check "nothing ran below the minimum version" test ! -e "$case/log.$comment"
  run "comment at the minimum version" 0 MODE=comment VERSION="$TOOL_COMMENT_MIN_VERSION" "${pr[@]}"
  run "comment at a later major version" 0 MODE=comment VERSION="$((major + 1)).0.0" "${pr[@]}"
  run "report below the minimum version" 0 MODE=report VERSION="$below"
fi
run "comment with version latest" 0 MODE=comment VERSION=latest "${pr[@]}"

run "install" 0 &&
  check "install: version and path outputs" test "$(out version)" = "$TOOL_VERSION" -a -n "$(out path)"
check "install: no command ran" test -z "$(compgen -G "$case/log*" || true)"

# Report mode: one run with every format, the gates and the user's arguments.
run "report" 0 MODE=report FAIL_ON=$'a, b\nc' ARGS=$'--flag\nvalue with spaces\r\n\n--last'
check "report: default command $report" test -f "$case/log.$report"
check "report: json file" grep -q '^json=' "$case/log.$report"
check "report: md file" grep -q '^md=' "$case/log.$report"
check "report: fail-on values" logged "$report" --fail-on a --fail-on b --fail-on c
check "report: args keep spaces and drop empty lines" logged "$report" --flag "value with spaces" --last
check "report: exit-code 0" test "$(out exit-code)" = 0
check "report: json-file" exists json-file
check "report: md-file" exists md-file
check "report: summary has the Markdown" grep -q "stub md for $report" "$case/summary"
check "report: annotations on stdout" grep -q '^::warning' "$case/stdout"
check "report: no comment" test ! -e "$case/log.notify"
if has "$report" "$TOOL_SARIF_COMMANDS"; then
  check "report: --format github" logged "$report" --format github
  check "report: sarif-file" exists sarif-file
  check "report: sarif-category" test "$(out sarif-category)" = "$TOOL_NAME-$report"
else
  check "report: --format plain" logged "$report" --format plain
  check "report: no sarif-file" test -z "$(out sarif-file)"
fi

run "report, gate matched" 3 MODE=report STUB_EXIT=3 STEP_SUMMARY=false
check "gate: exit-code 3" test "$(out exit-code)" = 3
check "gate: files still listed" exists json-file
check "step-summary false: empty summary" test ! -s "$case/summary"

run "report in a subdirectory" 0 MODE=report WORKING_DIRECTORY=./sub/dir/
check "subdirectory: the command ran there" grep -q 'sub/dir$' "$case/log.$report.pwd"
if has "$report" "$TOOL_SARIF_COMMANDS"; then
  check "subdirectory: sarif-category" test "$(out sarif-category)" = "$TOOL_NAME-$report/sub/dir"
  run "absolute directory in the workspace" 0 MODE=report GITHUB_WORKSPACE="$work" \
    WORKING_DIRECTORY="$work/case$((n + 1))/repo/sub/dir"
  check "workspace: sarif-category" test "$(out sarif-category)" = "$TOOL_NAME-$report/case$n/repo/sub/dir"
  run "absolute directory outside the workspace" 0 MODE=report GITHUB_WORKSPACE=/elsewhere \
    WORKING_DIRECTORY="$work/case$((n + 1))/repo/sub/dir"
  check "outside: sarif-category" test "$(out sarif-category)" = "$TOOL_NAME-$report/dir"
fi

if [[ -z "$TOOL_FROM_FLAG" ]]; then
  run "from without a from flag" 2 MODE=report FROM=plans && stderr_has "has no input that from sets"
else
  run "from without its file" 0 MODE=report FROM=plans
  check "from: flag" logged "$report" "$TOOL_FROM_FLAG" plans
  check "from: no file flag without the file" test -z "$(grep -Fx -- "$TOOL_FROM_FILE_FLAG" "$case/log.$report" || true)"
  with_file=$TOOL_FROM_FILE
  run "from with its file" 0 MODE=report FROM=plans
  check "from: file flag" logged "$report" "$TOOL_FROM_FILE_FLAG" "plans/$TOOL_FROM_FILE"
  run "from with the file flag in args" 0 MODE=report FROM=plans ARGS="$TOOL_FROM_FILE_FLAG=other.json"
  check "from: args win" test "$(grep -Fc -- "$TOOL_FROM_FILE_FLAG" "$case/log.$report")" = 1
  plans=$work/case$((n + 1))/repo/plans
  run "absolute from with its file" 0 MODE=report FROM="$plans"
  check "absolute from: file flag" logged "$report" "$TOOL_FROM_FILE_FLAG" "$plans/$TOOL_FROM_FILE"
  if command -v cygpath >/dev/null 2>&1; then
    plans=$(cygpath -w "$work/case$((n + 1))/repo/plans")
    run "Windows from with its file" 0 MODE=report FROM="$plans"
    check "Windows from: file flag" logged "$report" "$TOOL_FROM_FILE_FLAG" "$plans/$TOOL_FROM_FILE"
  fi
  with_file=
fi

# Comment mode: each command gets its own TOOL_COMMENT_FLAGS_<command> first, and only those.
comment_flags() {
  local cmd=$1 flags_var=TOOL_COMMENT_FLAGS_$1 flags=()
  if [[ -n "${!flags_var:-}" ]]; then read -r -a flags <<<"${!flags_var}"; fi
  check "comment: $cmd starts with its flags" \
    test "$(head -n $((${#flags[@]} + 1)) "$case/log.$cmd" | tr '\n' ' ')" = "$cmd ${flags[*]+${flags[*]} }"
}
for cmd in $TOOL_COMMENT_COMMANDS; do
  [[ "$cmd" == "$comment" ]] && continue
  run "comment with $cmd" 0 MODE=comment COMMAND="$cmd" "${pr[@]}"
  comment_flags "$cmd"
  check "comment: notify after $cmd" logged notify notify --from
done

run "comment" 0 MODE=comment "${pr[@]}"
check "comment: default command $comment" test -f "$case/log.$comment"
comment_flags "$comment"
check "comment: notify" logged notify notify --from
check "comment: github-pr-comment" logged notify --notify github-pr-comment
check "comment: summary too" grep -q "stub md for $comment" "$case/summary"

run "comment, gate matched" 3 MODE=comment STUB_EXIT=3 "${pr[@]}"
check "gate: comment still posted" test -f "$case/log.notify"

run "comment, notify refused" 4 MODE=comment STUB_NOTIFY_EXIT=4 "${pr[@]}"
check "notify refused: exit-code is the command's" test "$(out exit-code)" = 0

run "comment from a fork" 0 MODE=comment STEP_SUMMARY=false "${pr[@]}" HEAD_REPO=fork/repo
check "fork: no comment" test ! -e "$case/log.notify"
check "fork: notice" stderr_has "comes from the fork fork/repo"
check "fork: summary even with step-summary false" grep -q "stub md for $comment" "$case/summary"

run "comment from Dependabot" 0 MODE=comment "${pr[@]}" "GITHUB_ACTOR=dependabot[bot]"
check "Dependabot: no comment" test ! -e "$case/log.notify"
check "Dependabot: notice" stderr_has "read-only token"

run "comment without a head repository" 0 MODE=comment "${pr[@]}" HEAD_REPO=
check "no head repository: no comment" test ! -e "$case/log.notify"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all run tests passed"
