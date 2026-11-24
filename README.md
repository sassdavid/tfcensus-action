# tfcensus-action

A composite GitHub Action that installs a verified [tfcensus](https://github.com/sassdavid/tfcensus)
release on Linux, macOS and Windows runners. In report mode it runs `tfcensus drift` and sends the
drifted units to code scanning. In comment mode it also keeps one comment with the drift report on
the pull request.

The action is on the [GitHub Marketplace](https://github.com/marketplace/actions/tfcensus).

The action never takes AWS credentials. Run `aws-actions/configure-aws-credentials` and set up
terragrunt and terraform before it.

## Usage

Pin the action by commit SHA. Each `vX.Y.Z` release is immutable. The `v1` tag moves to the
newest 1.x release and has no release of its own.

### Install

```yaml
steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
  - uses: sassdavid/tfcensus-action@281f0a0735aa5770702f383cabd303372b0f6a00 # v1.2.1
  - run: tfcensus drift
```

### Report

One `tfcensus drift` run writes JSON, Markdown, SARIF and annotations. The action uploads the
SARIF to code scanning and appends the Markdown to the step summary. A `fail-on` match exits 3 and
fails the step after the upload.

`from` names the `--json-out-dir` of an earlier `terragrunt run --all` step. The action passes it
as `--from-json-out-dir`, and passes `<from>/report.json` as `--report-file` when that file exists
and `args` has no `--report-file`. Without `from`, tfcensus runs terragrunt itself.

```yaml
on:
  schedule:
    - cron: "17 6 * * *"
  workflow_dispatch:

permissions: {}

jobs:
  drift:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write # OIDC token for the AWS role
      security-events: write # the SARIF upload
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@90f833d396d0cc3674b631d2d225e306476c303a # v5.2.10, installs terragrunt and terraform
      - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        with:
          role-to-assume: ${{ vars.DRIFT_ROLE_ARN }}
          aws-region: eu-west-1
      - name: terragrunt plan -refresh-only
        run: |
          terragrunt run --all --json-out-dir "$RUNNER_TEMP/plans" \
            --report-file "$RUNNER_TEMP/plans/report.json" --report-format json \
            -- plan -refresh-only -lock=false -detailed-exitcode || true
      - uses: sassdavid/tfcensus-action@281f0a0735aa5770702f383cabd303372b0f6a00 # v1.2.1
        with:
          mode: report
          from: ${{ runner.temp }}/plans
          fail-on: drift
```

The alerts are under Security > Code scanning, in the category `tfcensus-drift`. With a
`working-directory` other than the repository root, the category ends with `/<directory>`. SARIF
locations are the units' `terragrunt.hcl` files relative to `working-directory`, so code scanning
links to the right file only when that directory is the repository root.

### Comment

Comment mode runs the same report on a `pull_request` event, then `tfcensus notify` keeps one
comment with it: a re-run edits it, and only when the report changed. Drift that is gone turns the
comment into "Nothing to report".

A pull request from a fork or from Dependabot gets a read-only `GITHUB_TOKEN` and no OIDC token.
The action then skips the comment, says why in a notice, and writes the report to the step
summary. Without AWS credentials such a run has nothing to plan, so a job that needs them should
skip forks with `if: github.event.pull_request.head.repo.full_name == github.repository`.

```yaml
on:
  pull_request:
    paths: ["**/*.hcl", "**/*.tf", ".tfcensus.yaml"]

permissions: {}

jobs:
  drift:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write # OIDC token for the AWS role
      pull-requests: write # the comment
    steps:
      # checkout, mise, AWS credentials and terragrunt as in the report example
      - uses: sassdavid/tfcensus-action@281f0a0735aa5770702f383cabd303372b0f6a00 # v1.2.1
        with:
          mode: comment
          from: ${{ runner.temp }}/plans
          sarif: false
```

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `version` | the pin in `scripts/tool.env` | tfcensus version: `X.Y.Z`, `vX.Y.Z` or `latest` |
| `verify` | `attestation` | the check after sha256: `attestation`, `cosign` or `checksum` |
| `mode` | `install` | `install`, `report` or `comment` |
| `command` | `drift` | report and comment mode take `drift` |
| `args` | | more arguments for the command, one per line |
| `from` | | plans directory: `--from-json-out-dir`, plus `--report-file` for its `report.json` |
| `fail-on` | | `--fail-on` values, separated by commas or newlines |
| `sarif` | `true` | upload the SARIF to code scanning |
| `step-summary` | `true` | append the Markdown to the step summary |
| `github-token` | `${{ github.token }}` | token for `gh attestation verify`, the SARIF upload and the comment |
| `working-directory` | `.` | directory the command runs in |

A bad input exits 2 before the install: an unknown mode or command, or `command`, `args`,
`from` or `fail-on` in install mode.

## Outputs

| Output | Meaning |
|---|---|
| `version` | the installed version, without a leading `v` |
| `path` | absolute path of the tfcensus binary |
| `exit-code` | the command's exit code: 0, 1 (a unit failed), 2 (usage), 3 (`fail-on` matched) or 4 (auth) |
| `json-file` | absolute path of the JSON report |
| `sarif-file` | absolute path of the SARIF file |
| `md-file` | absolute path of the Markdown report |

The step fails with the command's exit code. In comment mode a refused comment fails it with
notify's code when the command passed.

## Verification

The action checks every archive against the release's `checksums.txt` (sha256), then runs the
check that `verify` names. There is no option to skip verification.

- `attestation` runs `gh attestation verify` with `--signer-workflow
  sassdavid/tfcensus/.github/workflows/release.yml` and `--deny-self-hosted-runners`. GitHub-hosted
  runners have `gh`.
- `cosign` runs `cosign verify-blob` on `checksums.txt` with the release's
  `checksums.txt.sigstore.json`, for a certificate from tfcensus's release workflow. It uses
  `cosign` from PATH. Without it, mise installs the cosign version that `scripts/install.sh`
  pins. Without either, the step fails.
- `checksum` stops after sha256. It catches a broken download, not a replaced release.

## Development

```sh
mise run check          # jactionlint, shellcheck, prose lint, install tests (network and gh), run tests
mise run sibling:diff   # compare the files shared with tfcensus-action and tfcensus
```

CI runs the install and run tests and the action itself on ubuntu, macos and windows, and zizmor in
`security.yml`. `renovate.yml` runs Renovate weekly as the `sassdavid-renovate` GitHub App, and
`renovate-config.yml` validates `renovate.json` on pull requests. `scripts/test-run.sh` runs
`scripts/run.sh` with a stub binary: the inputs, the arguments each mode builds, the outputs, the
exit codes, and the comment rules for forks and Dependabot. Report and comment mode run for real on
[sassdavid/action-test](https://github.com/sassdavid/action-test).

## License

Apache-2.0. See [LICENSE](LICENSE).
