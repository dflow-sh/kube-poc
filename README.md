# dFlow kube-poc

dFlow is a Kubernetes application platform. This repository is the API server,
the `dflow` CLI, and the Helm chart. There is no UI in this tree. `apps/web`
is reserved for a later UI.

The server and CLI implement the dFlow API and command set.
See `NOTICE` and `LICENSE` (Apache-2.0). Copyright and license notices
live in `NOTICE`, `LICENSE`, and source file headers.

## Install the CLI

```bash
curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh
```

The script is `scripts/cli/install.sh`. Every GitHub release publishes it as `install.sh`. It does not need a clone or a token. It selects `linux` or `darwin` and `amd64` or `arm64`, downloads `dflow-<os>-<arch>`, and checks the SHA256 in `checksums.txt`. A missing asset or a checksum mismatch exits non-zero.

The default version is `latest`. The default directory is `/usr/local/bin` when that directory is writable or passwordless sudo works (`sudo -n`). If it is not writable, passwordless sudo is unavailable, and `/dev/tty` can be read, the script asks before running sudo. The question and the sudo password are read from `/dev/tty`, so `curl | sh` can still prompt. Declining, or running with no terminal, installs to `~/.local/bin` and prints a PATH hint. Running it again replaces the same binary. If `dflow` on `PATH` is a different file from the one just installed, the script prints both paths.

```bash
curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh -s -- --version vX.Y.Z
curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh -s -- --install-dir "$HOME/.local/bin"
```

`--version` selects a release tag, or `latest`. `--install-dir` selects the directory. `DFLOW_VERSION` and `DFLOW_INSTALL_DIR` are the same choices when the flags are omitted.

When it finishes it runs `dflow version` and prints the next step, `dflow login`. `dflow login` takes the API URL. `-u` / `--user` and `-p` / `--password` set the user and password. `--trust-ca` trusts an unknown certificate.

`dflow upgrade --cli-only` later replaces this binary from a public release. `dflow upgrade` also accepts `--version`, `--server-only`, and `--dry-run`. Those flags are in this tree. The published `v0.0.4` binary does not include `dflow upgrade`.

`install.sh` is not an asset on the `v0.0.4` release. `releases/latest/download/install.sh` works once a release that contains this script is published.

On macOS, a browser-downloaded binary may need `xattr -d com.apple.quarantine /usr/local/bin/dflow`. The installer removes that attribute when `xattr` is present.

## Layout

- `apps/cli` builds the `dflow` binary
- `apps/api` builds the `dflow-server` binary (`dflow server`)
- `packages/dflow` is the shared server and CLI code
- `packages/application` is the `application.dflow.sh` API types
- `packages/helm-chart` is the `dflow` Helm chart
- `acceptance/` is the cluster acceptance suite and is not part of `turbo test`

## Build

Go 1.26 and pnpm are required.

```bash
pnpm install
pnpm exec turbo build
pnpm exec turbo test
pnpm exec turbo lint
```

Binaries:

- `apps/cli/dist/dflow`
- `apps/api/dist/dflow-server`

Unreleased builds report `v0.0.0-dev` (`packages/dflow/version/version.go`). A release tag stamps the CLI, the server image, `/info`, Swagger, and the packaged chart from that tag. `scripts/check-version.sh` fails if those copies disagree.

Install on a server: [docs/INSTALL.md](docs/INSTALL.md). Check it with [docs/TESTING.md](docs/TESTING.md).

The CLI, `install.sh`, `checksums.txt`, and the Helm chart are public GitHub Release assets. No token is required:

```text
https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/dflow-<os>-<arch>
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/checksums.txt
```

Published names are `install.sh`, `dflow-linux-amd64`, `dflow-linux-arm64`, `dflow-darwin-amd64`, `dflow-darwin-arm64`, `checksums.txt`, an SPDX SBOM for each CLI binary (`dflow-<os>-<arch>.spdx.json`), and the chart `dflow-<version>.tgz`. `checksums.txt` lists the CLI binaries, the chart tarball, and `install.sh`. Keyless Sigstore bundles (`<name>.sigstore.json`) are published for the signed blobs, including `checksums.txt`. The chart and `install.sh` do not have their own `.sigstore.json`; check them with the checksum file. The server image is signed in the registry. Tag `v0.0.4` publishes `dflow-0.0.4.tgz` and the four CLI binaries. It does not publish `install.sh`, SBOMs, or signatures.

Verify a release with cosign 3. Replace the tag. The identity is the GitHub Actions workflow that ran for that tag, and the issuer is GitHub's OIDC token endpoint. No signing key is stored in the repository.

```bash
tag=v0.1.0
base="https://github.com/dflow-sh/kube-poc/releases/download/${tag}"
curl -fsSL -o checksums.txt "${base}/checksums.txt"
curl -fsSL -o checksums.txt.sigstore.json "${base}/checksums.txt.sigstore.json"
cosign verify-blob \
  --bundle checksums.txt.sigstore.json \
  --certificate-identity "https://github.com/dflow-sh/kube-poc/.github/workflows/release.yml@refs/tags/${tag}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  checksums.txt
```

That verifies `checksums.txt`. Then check the chart tarball and `install.sh` against the signed checksum file. There is no `dflow-0.1.0.tgz.sigstore.json`.

```bash
sha256sum -c checksums.txt --ignore-missing
```

Verify the server image with the same identity. Image signing is proven when `v0.1.0` is published, not from a local snapshot, because keyless `cosign sign` runs in the tag workflow.

```bash
cosign verify \
  --certificate-identity "https://github.com/dflow-sh/kube-poc/.github/workflows/release.yml@refs/tags/${tag}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "ghcr.io/dflow-sh/dflow-server:${tag}"
```

Install the CLI with the command in [Install the CLI](#install-the-cli). From a checkout, `./scripts/install-cli.sh` installs `dflow` to `/usr/local/bin` and can log in and run the sample push. `sudo dflow upgrade` replaces that binary and then helm-upgrades the server to the same tag. `sudo dflow upgrade --cli-only` replaces only the CLI. `sudo ./scripts/update.sh` upgrades and then runs the install self-test. `make dflow` writes `dist/dflow`.

The installer starts embedded etcd and prints the worker join command and the `--control-plane` command for a second and third server. `scripts/join-node.sh` joins another Ubuntu machine as a worker, or as a server when `--control-plane` is set.

A local cluster smoke test is `scripts/e2e-smoke.sh`.

## Branching

All work branches from `dev`, and pull requests target `dev`. `main` is the public release branch. `dev` merges into `main` when the maintainer decides. Releases and tags are cut from `main`.

## Continuous integration

GitHub Actions run only on pull requests and pushes to `main`, and on `v*` tags. `ci.yml` is the pull-request and `main` push workflow. `release.yml` runs on `v*` tags. Pull requests into `dev` are verified locally.

## Dependabot

`.github/dependabot.yml` opens Go module, GitHub Actions, and image updates against `dev`.

## Image scan

`scripts/image-inventory.sh --scan` scans every digest-pinned image from the rendered charts and the install, update, and join scripts. `--check` fails a floating tag, `latest`, or a missing digest. CI runs:

```bash
bash scripts/image-inventory.sh --check --scan
```

For each pinned ref, `scan_pinned_images` runs:

```bash
trivy image \
  --quiet \
  --scanners vuln \
  --severity HIGH,CRITICAL \
  --list-all-pkgs=false \
  --exit-code 0 \
  --format json \
  --ignorefile "$ignore_file" \
  --timeout 15m \
  --output "$out" \
  "$ref"
```

`--exit-code 0` leaves the pass/fail decision to the script. It reads the JSON and exits 1 if any CRITICAL finding remains. HIGH findings are printed and do not fail the run. `--ignorefile ""` disables the default `.trivyignore`. There is no repository-wide ignore file.

The script sets `ignore_file` only for an exact ref match:

- `docker.io/emberstack/kubernetes-reflector` digest `sha256:51dbd5880929dc26678f6e190c70abfbcccd3846679ff464e5815823fd782f1a` (with or without tag `10.0.65`) uses `scripts/trivy-allow/kubernetes-reflector-10.0.65.trivyignore` for CVE-2026-70188 and CVE-2026-88092.
- `gcr.io/kaniko-project/executor` digest `sha256:2562c4fe551399514277ffff7dcca9a3b1628c4ea38cb017d7286dc6ea52f4cd` (with or without tag `v1.24.0-debug`) uses `scripts/trivy-allow/kaniko-executor-v1.24.0-debug.trivyignore` for CVE-2025-68121 and CVE-2026-33186.

Every other ref is scanned with an empty ignore file, so CVE-2025-68121 still fails on any image other than that kaniko pin.

To add an entry, put the CVE id on its own line in a file under `scripts/trivy-allow/`. The comment on the line above names the image, the CVE, and the phrase "accepted until upstream ships a patched tag". Add a `case` arm in `scan_pinned_images` that matches that exact ref and sets `ignore_file` to the file. To remove an entry, delete that CVE line, or delete the `case` arm.

## Pinned components

- cert-manager chart v1.21.2 (`packages/helm-chart/Chart.yaml`)
- k3s v1.36.5+k3s1 (`INSTALL_K3S_VERSION` in `scripts/install.sh`)
- Helm v3.22.1 (`HELM_VERSION` in `scripts/install.sh` and `VERSION` in `scripts/tools/helm.sh`)
- Go directive `go 1.26.0` and toolchain `go1.26.10` (`go.mod`). CI installs Go 1.26.10.
- `k8s.io/api`, `k8s.io/apimachinery`, `k8s.io/client-go`, `k8s.io/kubectl`, and `k8s.io/metrics` are v0.37.1. `sigs.k8s.io/controller-runtime` is v0.25.2.
