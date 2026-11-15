# tfcensus-action

Composite GitHub Action that installs a verified tfcensus release, then reports to code scanning or
keeps one pull request comment. The milestone is M14 in tfcensus's
`docs/plan/milestones.md` (`~/src/github/tfcensus`), the design is in its
`docs/plan/roadmap-research.md#github-action`.

## Verify (run before claiming anything works)
- `mise run check`: jactionlint (workflows and `action.yml`), shellcheck, the prose lint,
  `scripts/test-install.sh` (needs network and `gh`) and `scripts/test-run.sh` (offline, a stub
  binary). Must pass before every commit.
- Report and comment mode are proven on `sassdavid/action-test` (`~/src/github/action-test`):
  code scanning alerts, the sticky comment and the exit 3 gate.
- zizmor runs in CI (`security.yml`). Locally: `mise x zizmor -- zizmor .`.

## Layout
- `action.yml` runs `scripts/run.sh`, which runs `scripts/install.sh` and the mode, then uploads
  the SARIF with `github/codeql-action/upload-sarif`.
- `scripts/tool.env` is the only tool-specific file besides the README. It also lists the
  commands each mode takes and the flags `from` sets.
- `scripts/major-tag.sh` moves `v1`; `major-tag.yml` runs it when a release is published.

## Conventions
- Inputs reach scripts through `env:`, never through `${{ }}` inside `run:`.
- Every `uses:` is pinned by SHA, inside `action.yml` too. `permissions: {}` at the top of each
  workflow, and each job asks for what it needs.
- Exit 2 for a bad input, 1 for a failed download or check.
- Releases: release-please creates a draft `vX.Y.Z`. The owner publishes it in the web UI (the
  Marketplace box), release immutability locks it, and `major-tag.yml` moves `v1`. `v1` never
  gets a release.
- Conventional Commits. release-please owns versions and tags.

## Sibling repos
- tfcensus-action (`~/src/github/tfcensus-action`) is built the same way, and tfcensus
  (`~/src/github/tfcensus`) shares the writing rules and the sibling script. Follow
  `.claude/rules/siblings.md` and run `mise run sibling:diff`.

## Writing
- All text follows `.claude/rules/writing.md`. `mise run lint:prose` checks part of it.
