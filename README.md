# dFlow kube-poc

dFlow is a Kubernetes application platform. This repository is the API server,
the `dflow` CLI, and the Helm chart. There is no UI in this tree. `apps/web`
is reserved for a later UI.

The server and CLI follow the Epinio API and command set, rebranded as dFlow.
See `NOTICE` and `LICENSE` (Apache-2.0).

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

Install on a cluster: [docs/INSTALL.md](docs/INSTALL.md).

A local cluster smoke test is `scripts/e2e-smoke.sh`.
