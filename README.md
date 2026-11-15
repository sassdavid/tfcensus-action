# tfcensus-action

A composite GitHub Action that installs a verified [tfcensus](https://github.com/sassdavid/tfcensus)
release on Linux, macOS and Windows runners.

There is no release yet. v1.0.0 follows once the report and comment modes land (tfcensus milestone
M14).

## Usage

```yaml
steps:
  - uses: actions/checkout@<commit SHA> # v7.0.1
  - uses: sassdavid/tfcensus-action@<commit SHA> # v1.0.0
  - run: tfcensus drift
```

The action never takes AWS credentials. Run `aws-actions/configure-aws-credentials` and set up
terragrunt and terraform before it.

Pin the action by commit SHA. Each `vX.Y.Z` release is immutable. The `v1` tag moves to the
newest 1.x release and has no release of its own.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `version` | the pin in `scripts/tool.env` | tfcensus version: `X.Y.Z`, `vX.Y.Z` or `latest` |
| `verify` | `attestation` | the check after sha256: `attestation`, `cosign` or `checksum` |
| `mode` | `install` | what runs after the install; `install` only puts tfcensus on PATH |
| `github-token` | `${{ github.token }}` | token for `gh attestation verify` |

## Outputs

| Output | Meaning |
|---|---|
| `version` | the installed version, without a leading `v` |
| `path` | absolute path of the tfcensus binary |

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
mise run check          # jactionlint, shellcheck, prose lint, install tests (network and gh)
mise run sibling:diff   # compare the files shared with tfcensus-action and tfcensus
```

CI runs the install tests and the action itself on ubuntu, macos and windows, and zizmor in
`security.yml`.

## License

Apache-2.0. See [LICENSE](LICENSE).
