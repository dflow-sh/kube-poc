# Install dFlow

dFlow runs on Kubernetes. This page is what you provide, then the commands that install k3s, the chart dependencies, `dflow-server`, and the `dflow` CLI, and push a sample app.

The chart does not install a UI. `dflowUI.enabled` is false.

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
- an app in the `sample` namespace is `https://hello.sample.apps.example.com`

sslip.io needs no DNS account. With the same IP:

- domain `203.0.113.10.sslip.io`
- API `https://dflow.203.0.113.10.sslip.io`
- apps `https://<app>.<namespace>.203.0.113.10.sslip.io`

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
