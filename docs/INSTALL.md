# Install dFlow

dFlow runs on Kubernetes. The chart does not install a UI. `dflowUI.enabled` is false.

The repository is private. Clone it with a GitHub token or a deploy key, then run the installer from that checkout. Do not use a public raw URL; that URL returns 404 while the repository is private.

## One-shot install on Ubuntu

The server is Ubuntu 22.04 or 24.04, with at least 8 GB RAM, a public IPv4 address, and root SSH.

HTTPS with a personal access token that can read this repository:

```bash
git clone --branch cursor/m1-image-deploy-ccca \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/dflow-sh/kube-poc.git"
cd kube-poc
sudo --preserve-env=GITHUB_TOKEN ./scripts/install.sh --domain auto
```

`GITHUB_TOKEN` needs permission to read this private repository (`repo` on a classic token, or contents read on a fine-grained token). `sudo` drops the variable unless `--preserve-env=GITHUB_TOKEN` is set. `GH_TOKEN` is accepted as well. If neither is set, a `gh auth login` session for the user who invoked sudo is used. With no token and no `gh` login, the script builds the CLI and server image from the checkout.

To pull `ghcr.io/dflow-sh/dflow-server` from a release, the same token also needs `read:packages`. Set `GHCR_USER` to the GitHub login that owns the token. The script uses `GHCR_USER`, then `GITHUB_ACTOR`, then the login from `gh api user`.

Deploy key (read access is enough):

```bash
GIT_SSH_COMMAND='ssh -i ~/.ssh/dflow_deploy_key -o IdentitiesOnly=yes' \
  git clone --branch cursor/m1-image-deploy-ccca git@github.com:dflow-sh/kube-poc.git
cd kube-poc
sudo --preserve-env=GITHUB_TOKEN ./scripts/install.sh --domain auto
```

A deploy key can clone. It cannot download GitHub Release assets. Export `GITHUB_TOKEN` as well when a release should be used.

`--domain auto` uses `<public-ipv4>.sslip.io`. To use DNS you control:

```bash
sudo ./scripts/install.sh --domain apps.example.com
```

`apps.example.com` and `*.apps.example.com` must point at the server. The API is `https://dflow.<domain>`. An app named `hello` is `https://hello.<domain>`.

The script is safe to run again. It installs k3s when k3s is missing, turns off ServiceLB, puts Traefik on the host network so it binds the host address on ports 80 and 443, checks that Traefik's host IP is a node address, installs cert-manager, installs the dFlow chart, and installs the `dflow` CLI.

When a GitHub Release exists, the script downloads the `dflow` CLI, the Helm chart package (`dflow-*.tgz`), and the server image `ghcr.io/dflow-sh/dflow-server:<tag>` from that release. The CLI download is checked against `checksums.txt` when that file is in the release. No release has been published yet, so today the script builds those from the checkout and tags the server image `dev-<git sha>`. If the release download fails and the checkout build also fails, the script exits non-zero and names both failures. CI on this branch also uploads CLI binaries and a server image archive as workflow artifacts. That is not a production deploy.

When the script finishes it prints the API URL, the `admin` password, and the login command. It has already logged in, pushed `traefik/whoami`, required HTTP 200 from the app URL, deleted the app, and deleted the `sample` namespace. If any of those steps fail, the script exits non-zero and prints the step that failed.

Manual checks and uninstall: [docs/TESTING.md](TESTING.md).

The script also prints the k3s join URL and token. The URL is `https://<first-server-public-ipv4>:6443`.

## Add a worker

The first server stays the only control plane. Another Ubuntu 22.04 or 24.04 machine joins as a worker. Clone this private repository on that machine the same way as the first server (`GITHUB_TOKEN` for HTTPS, or a deploy key). The join command itself does not need a token beyond the k3s node token.

On the first server, after install, the URL and token are in the installer output. Print them again any time:

```bash
sudo dflow join-info
```

That reads `/var/lib/rancher/k3s/server/node-token` and `node-external-ip` from `/etc/rancher/k3s/config.yaml`. The same token file is:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

The server URL is `https://<first-server-public-ipv4>:6443`.

On the worker, from the checkout:

```bash
sudo ./scripts/join-node.sh \
  --server https://203.0.113.10:6443 \
  --token '<token from dflow join-info>'
```

Replace the IP and the token. The script installs the k3s agent and joins this host as a worker. Run it again with the same server and token and it leaves a healthy agent in place. A bad token, a server that does not answer `https://<ip>:6443/ping`, or a k3s agent that does not stay active exits non-zero and prints the reason. Do not run it on the first server.

On the first server, confirm the worker:

```bash
sudo kubectl get nodes
```

`kubectl` as root uses `/etc/rancher/k3s/k3s.yaml`. The new node is listed `Ready`. That can take a minute after the agent starts. The worker's `ROLES` column is empty. The first server is `control-plane`.

### Firewall

Allow these between the first server and every worker:

| Port | Protocol | Where |
| --- | --- | --- |
| 6443 | TCP | workers to the first server (Kubernetes API) |
| 8472 | UDP | all nodes, both directions (flannel VXLAN) |
| 10250 | TCP | all nodes, both directions (kubelet) |

If `scripts/install.sh` logged that this kernel is using flannel host-gw, UDP 8472 is unused. Nodes still need a route to each other.

The scripts do not change host firewall rules. When `ufw` is enabled, on each node:

```bash
sudo ufw allow 6443/tcp
sudo ufw allow 8472/udp
sudo ufw allow 10250/tcp
```

### High availability

This install is one k3s server plus workers. Later high availability is three server nodes with k3s embedded etcd. These scripts do not set that up.

## macOS CLI

Go 1.26 is required. From a checkout on the Mac:

```bash
make dflow
sudo install -m 0755 dist/dflow /usr/local/bin/dflow
dflow version
dflow login -u admin -p 'password' --trust-ca "https://dflow.<domain>"
```

`<domain>` and the password are what `scripts/install.sh` printed. `password` is the default.

The same push as the server self-test:

```bash
dflow namespace create sample
dflow target sample
dflow push -n hello --container-image-url traefik/whoami
curl -k -sS -D - "https://hello.<domain>/" -o /tmp/whoami-body | head -n 1
dflow app delete hello
dflow namespace delete sample -f
```

Expected: login prints `Login successful`, push prints `App is online.` and `https://hello.<domain>`, curl prints `HTTP/2 200` or `HTTP/1.1 200 OK`, delete prints `Applications Removed.`

`make dflow-darwin` writes both `dist/dflow-darwin-arm64` and `dist/dflow-darwin-amd64`. Use the one that matches the Mac:

```bash
sudo install -m 0755 dist/dflow-darwin-arm64 /usr/local/bin/dflow
```

Without Make:

```bash
CGO_ENABLED=0 go build -o dist/dflow ./apps/cli
sudo install -m 0755 dist/dflow /usr/local/bin/dflow
```

CI on this branch uploads `dflow-darwin-arm64` and `dflow-darwin-amd64` as workflow artifacts. With access to the private repository:

```bash
gh run list --repo dflow-sh/kube-poc --branch cursor/m1-image-deploy-ccca --workflow ci --limit 1
gh run download --repo dflow-sh/kube-poc <run-id> -n dflow-darwin-arm64
sudo install -m 0755 dflow-darwin-arm64 /usr/local/bin/dflow
```

Building locally does not wait on that artifact.

### scripts/install-cli.sh

From a Mac checkout, this installs the matching `darwin-arm64` or `darwin-amd64` binary to `/usr/local/bin/dflow`, then logs in and runs the sample push when `--api` is set.

```bash
export GITHUB_TOKEN=...   # or: gh auth login
./scripts/install-cli.sh \
  --api "https://dflow.<domain>" \
  --user admin \
  --password 'password'
```

`<domain>` and the password are what `scripts/install.sh` printed on the server. The script downloads `dflow-darwin-arm64` or `dflow-darwin-amd64` from the latest GitHub Release and checks `checksums.txt` when that file is in the release. With no release asset, it runs `go build` from the checkout (Go 1.26). If both fail, it exits non-zero.

Without `--api` the binary is still installed and the script prints the login and push commands instead of running them.

## Upgrade

On the server, after the one-shot install:

```bash
sudo --preserve-env=GITHUB_TOKEN ./scripts/update.sh
```

That selects the latest GitHub Release, runs `helm upgrade`, waits until `dflow-server` is ready, then repeats the API health check and the CLI self-test (login, push `traefik/whoami`, curl expecting HTTP 200, delete, confirm the sample namespace is gone).

A specific release:

```bash
sudo --preserve-env=GITHUB_TOKEN ./scripts/update.sh v1.0.0
```

If that tag does not exist, the script stops. It does not build a different commit and label it with the missing tag. If no latest release exists, it builds from the checkout, tags the image `dev-<git sha>`, upgrades with that image, and still runs the self-test. `GITHUB_TOKEN` (or `GH_TOKEN`) needs repository read for the release, and `read:packages` plus `GHCR_USER` when the server image is pulled from ghcr.io.

CLI only, on the server or on a Mac:

```bash
export GITHUB_TOKEN=...   # or: gh auth login
./scripts/update.sh --cli
./scripts/update.sh --cli v1.0.0
```

`--cli` replaces `/usr/local/bin/dflow` with the release binary for this OS and CPU, or builds it from the checkout when the release asset is missing.

## Release workflow

`.github/workflows/release.yml` runs only when a tag matching `v*` is pushed. For example `v1.0.0`. It uses GoReleaser. The tag must point at a commit that already contains that workflow file. Pushing the tag is the only trigger. Do not run it by hand from a pull request.

```bash
git checkout main
git pull
git tag v1.0.0
git push origin v1.0.0
```

The workflow then:

- publishes `dflow-linux-amd64`, `dflow-linux-arm64`, `dflow-darwin-amd64`, and `dflow-darwin-arm64`, plus `checksums.txt`, as GitHub Release assets
- pushes `ghcr.io/dflow-sh/dflow-server:<tag>` and `ghcr.io/dflow-sh/dflow-server:latest`
- packages the Helm chart, sets its version and the server image tag to the git tag, and uploads `dflow-<version>.tgz` on the same release

Actions uses the workflow `GITHUB_TOKEN` (`contents: write` and `packages: write`). No extra secret is required for this repository. This is not a production deploy of a cluster.

## What you provide

One virtual machine:

- Ubuntu 22.04 or 24.04
- at least 4 vCPU, 8 GB RAM, and 80 GB disk
- a public IPv4 address
- root SSH
- a DNS name for the API and for apps

DNS is either a wildcard you control, or [sslip.io](https://sslip.io).

Wildcard example, public IP `203.0.113.10`, domain `apps.example.com`:

- `apps.example.com` and `*.apps.example.com` both point at `203.0.113.10`
- the API is `https://dflow.apps.example.com`
- an app named `hello` is `https://hello.apps.example.com` (`dflow target` selects the namespace; the hostname does not include it)

sslip.io needs no DNS account. With the same IP:

- domain `203.0.113.10.sslip.io`
- API `https://dflow.203.0.113.10.sslip.io`
- apps `https://<app>.203.0.113.10.sslip.io`

`sslip.io` answers for that name and for `*.203.0.113.10.sslip.io`.

Change the default admin password before the host is reachable on the internet. The chart default user is `admin` / `password`.

## Tools on the machine

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Go 1.26 is required only to build the server image. The published chart value `ghcr.io/dflow-sh/dflow-server:v1.14.3` is not on the registry yet, so build it on the machine (next section) or push that tag from CI and skip the build.

## 1. Install k3s

k3s includes Traefik, which is the ingress controller the chart expects. The chart does not install ingress itself.

```bash
curl -sfL https://get.k3s.io | sudo sh - --write-kubeconfig-mode 644
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo kubectl get nodes
```

Wait until the node is `Ready` and the `traefik` pod in `kube-system` is `Running`.

k3s ServiceLB (`svclb-traefik`) can fail to claim ports 80 and 443, so the Traefik service never receives the host IP. `scripts/install.sh` avoids that by disabling ServiceLB and running Traefik on the host network, listening on 80 and 443. Use the script on a fresh server. The manual steps below assume Traefik is already reachable on those ports.

## 2. Build and load dflow-server

On the machine, from a checkout of this repository:

```bash
# https://go.dev/dl/go1.26.0.linux-amd64.tar.gz
export PATH=/usr/local/go/bin:$PATH
CGO_ENABLED=0 go build -o apps/cli/dist/dflow ./apps/cli
docker build -f images/Dockerfile -t ghcr.io/dflow-sh/dflow-server:v1.14.3 .
docker save ghcr.io/dflow-sh/dflow-server:v1.14.3 | sudo k3s ctr images import -
```

If Docker is not installed, `sudo apt-get install -y docker.io` and start the daemon. k3s uses containerd, so the image has to be imported with `k3s ctr`. Pulling from a registry you pushed the same tag to also works. The chart sets `image.pullPolicy` to `IfNotPresent`, so a node that already has the image does not try the registry.

The image entrypoint is the `dflow` CLI. The chart runs `/dflow server`.

## 3. Install the chart

The chart installs, when you turn the switches on:

- cert-manager (the bundled chart, installed first so its CRDs exist)
- the container registry (`containerregistry.enabled`, default true)
- S3-compatible storage via SeaweedFS (`seaweedfs.enabled`, default true)
- the Paketo builder image reference (`image.builder`, `paketobuildpacks/builder-jammy-full`)

s3gw is the other S3-compatible option and is off by default. MinIO is not installed by the chart. To use MinIO, set `seaweedfs.enabled=false`, `s3gw.enabled=false`, and set `s3.endpoint`, `s3.accessKeyID`, `s3.secretAccessKey`, and `s3.bucket`.

Dex, the source unpacker, and the Dockerfile builder are published upstream images. See `NOTICE`. A container-image push does not pull the Paketo builder.

Install cert-manager from the chart bundled in this repo, then dFlow. The dFlow manifests include `Certificate` resources, so the cert-manager CRDs have to exist before that install.

```bash
export DOMAIN=203.0.113.10.sslip.io   # or apps.example.com

helm upgrade --install cert-manager packages/helm-chart/charts/cert-manager-v1.19.3.tgz \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10m

helm upgrade --install dflow packages/helm-chart \
  --namespace dflow --create-namespace \
  --set global.domain="$DOMAIN" \
  --set certManager.install=false \
  --set certManager.enabled=true \
  --set dflowUI.enabled=false \
  --set api.adminPassword='replace-this-password'
```

Wait until the API is ready:

```bash
kubectl -n dflow rollout status deploy/dflow-server --timeout=15m
kubectl -n dflow get pods
```

## 4. Install the CLI

```bash
sudo install -m 0755 apps/cli/dist/dflow /usr/local/bin/dflow
dflow version
```

## 5. Log in and push a sample

```bash
dflow login -u admin -p 'replace-this-password' \
  --trust-ca \
  "https://dflow.${DOMAIN}"

dflow namespace create sample
dflow target sample

# container image: no Paketo build
dflow push -n hello --container-image-url traefik/whoami

dflow app list
dflow app logs hello
dflow app delete hello
```

`dflow app logs` without `--follow` prints the current logs and returns. Add `--follow` to stream.

Source push, which does use the builder, is the same command with a directory:

```bash
dflow push -n hello -p assets/sample-app
```

## Existing cluster

Skip the k3s section when you already have a cluster. You need a kubeconfig with permission to create namespaces, CRDs, and cluster-scoped roles, plus an ingress controller (Traefik or nginx) and a wildcard DNS name that reaches that ingress.

```bash
export KUBECONFIG=/path/to/kubeconfig
kubectl get nodes
```

Then follow sections 2 through 5. Load the server image into every node that might run `dflow-server`, or push it to a registry the cluster can pull. Set `ingress.ingressClassName` if the cluster does not use the default ingress class.

```bash
helm upgrade --install cert-manager packages/helm-chart/charts/cert-manager-v1.19.3.tgz \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10m

helm upgrade --install dflow packages/helm-chart \
  --namespace dflow --create-namespace \
  --set global.domain="$DOMAIN" \
  --set certManager.install=false \
  --set certManager.enabled=true \
  --set dflowUI.enabled=false \
  --set ingress.ingressClassName=traefik \
  --set api.adminPassword='replace-this-password'
```

If cert-manager is already installed, skip that release and keep `certManager.install=false` with `certManager.enabled=true`.

## Local k3d smoke

`scripts/e2e-smoke.sh` boots a k3d cluster, imports a locally built server image, installs the chart, logs in through a port-forward, pushes `traefik/whoami`, lists it, reads logs, and deletes it. That script is the check used in this repository. It is not a substitute for the VPS steps above: the laptop or build VM has no public wildcard, so the script reaches the API with `kubectl port-forward`.
