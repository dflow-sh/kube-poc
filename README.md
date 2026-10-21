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

Install on a server: [docs/INSTALL.md](docs/INSTALL.md). Check it with [docs/TESTING.md](docs/TESTING.md).

On a Mac, `./scripts/install-cli.sh` installs `dflow` to `/usr/local/bin`. `make dflow` writes `dist/dflow`. `scripts/update.sh` upgrades a server that was installed with `scripts/install.sh`. That installer starts embedded etcd and prints the worker join command and the `--control-plane` command for a second and third server. `scripts/join-node.sh` joins another Ubuntu machine as a worker, or as a server when `--control-plane` is set.

A local cluster smoke test is `scripts/e2e-smoke.sh`.
