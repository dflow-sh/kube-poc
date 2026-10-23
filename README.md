# dFlow kube-poc

dFlow is a Kubernetes application platform. This repository is the API server,
the `dflow` CLI, and the Helm chart. There is no UI in this tree. `apps/web`
is reserved for a later UI.

The server and CLI implement the dFlow API and command set.
See `NOTICE` and `LICENSE` (Apache-2.0).

Changes: user-visible naming in this file is dFlow. Upstream copyright and
license notices are unchanged and live in `NOTICE`, `LICENSE`, and the
copyright headers of derived source files.

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
