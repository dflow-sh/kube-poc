# dFlow kube-poc

dFlow is a Kubernetes application platform. This repository is the API server,
the `dflow` CLI, and the Helm chart. There is no UI in this tree. `apps/web`
is reserved for a later UI.

The server and CLI implement the dFlow API and command set.
See `NOTICE` and `LICENSE` (Apache-2.0). Copyright and license notices
live in `NOTICE`, `LICENSE`, and source file headers.

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

The CLI, `checksums.txt`, and the Helm chart are public GitHub Release assets. No token is required:

```text
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/dflow-<os>-<arch>
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/checksums.txt
```

Published names are `dflow-linux-amd64`, `dflow-linux-arm64`, `dflow-darwin-amd64`, `dflow-darwin-arm64`, and `checksums.txt`. Tag `v0.0.4` also publishes `dflow-0.0.4.tgz`.

From a checkout, `./scripts/install-cli.sh` installs `dflow` to `/usr/local/bin`. `sudo dflow upgrade` replaces that binary and then helm-upgrades the server to the same tag. `sudo ./scripts/update.sh` does the same and then runs the install self-test. `make dflow` writes `dist/dflow`.

A one-line `curl | bash` install is not available yet: `scripts/install-cli.sh` sources `scripts/install.sh`, so that file alone is not an installer. On macOS, a browser-downloaded binary may need `xattr -d com.apple.quarantine /usr/local/bin/dflow`.

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
