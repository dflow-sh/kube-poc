# Install dFlow

dFlow runs on Kubernetes. The chart does not install a UI. `dflowUI.enabled` is false.

The repository is private. Clone it with a GitHub token or a deploy key, then run the installer from that checkout. Do not use a public raw URL; that URL returns 404 while the repository is private.

## One-shot install on Ubuntu

The server is Ubuntu 22.04 or 24.04, with at least 8 GB RAM, a public IPv4 address, and root SSH.

HTTPS with a personal access token that can read this repository:

```bash
git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/dflow-sh/kube-poc.git"
cd kube-poc
sudo --preserve-env=GITHUB_TOKEN ./scripts/install.sh --domain auto
```

`GITHUB_TOKEN` needs permission to read this private repository (`repo` on a classic token, or contents read on a fine-grained token). `sudo` drops the variable unless `--preserve-env=GITHUB_TOKEN` is set. `GH_TOKEN` is accepted as well. If neither is set, a `gh auth login` session for the user who invoked sudo is used. With no token and no `gh` login, the script builds the CLI and server image from the checkout.

To pull `ghcr.io/dflow-sh/dflow-server` from a release, the token also needs `read:packages`. Set `GHCR_USER` to the GitHub login that owns the token, or set `GHCR_TOKEN` to a token that already has `read:packages`. The script uses `GHCR_TOKEN` first, then `GITHUB_TOKEN` or `GH_TOKEN`. The username is `GHCR_USER`, then `GITHUB_ACTOR`, then the login from `gh api user`.

If the package is private and the pull returns 403, the script says so and builds from the checkout. To stop that fallback, make the package public: GitHub → Packages → `dflow-server` → Package settings → Change visibility → Public.

Deploy key (read access is enough):

```bash
GIT_SSH_COMMAND='ssh -i ~/.ssh/dflow_deploy_key -o IdentitiesOnly=yes' \
  git clone git@github.com:dflow-sh/kube-poc.git
cd kube-poc
sudo --preserve-env=GITHUB_TOKEN ./scripts/install.sh --domain auto
```

A deploy key can clone. It cannot download GitHub Release assets. Export `GITHUB_TOKEN` as well when a release should be used.

### Domains and certificates

On a terminal, with no domain flags, the script asks for an API host (example `paas.dflow.sh`), an apps wildcard base (example `apps.dflow.sh`, so an app is `hello.apps.dflow.sh`), and a Let's Encrypt email. Press Enter on each line to keep `<public-ipv4>.sslip.io` and a self-signed certificate.

The same answers are flags or environment variables:

```bash
sudo ./scripts/install.sh \
  --api-domain paas.dflow.sh \
  --apps-domain apps.dflow.sh \
  --email ops@dflow.sh
```

`DFLOW_API_DOMAIN`, `DFLOW_APPS_DOMAIN`, and `DFLOW_EMAIL` (or `LETSENCRYPT_EMAIL`) match those flags. `--domain apps.example.com` is the older form: the API is `https://dflow.apps.example.com` and apps are `https://<app>.apps.example.com`. `--domain auto` uses `<public-ipv4>.sslip.io`.

A custom domain requires an email. The chart then uses the `letsencrypt-production` ClusterIssuer (HTTP-01 through Traefik) for the API and for every app route. Login and curl do not need `--trust-ca` or `-k`. `--letsencrypt-staging` uses `letsencrypt-staging` instead; those certificates are still untrusted, so login keeps `--trust-ca`. `*.sslip.io` stays on the internal `dflow-ca` issuer unless you pass `--letsencrypt-staging` and `--email`.

Before certificates are requested, the script prints the records and waits until they resolve to the public IPv4:

```text
A    paas.dflow.sh        <public-ipv4>
A    *.apps.dflow.sh      <public-ipv4>
```

`*.sslip.io` does not wait. A second run with no domain flags, or with `--domain auto` again, reuses `/var/lib/dflow/install.env`, including the saved password unless you pass `--admin-password`. That keeps the same sslip.io name when the public-IP lookup would otherwise return a different egress address.

### No public IPv4

If no public IPv4 is detected, an interactive run asks whether to use a Cloudflare Tunnel. Non-interactive:

```bash
sudo ./scripts/install.sh \
  --api-domain paas.dflow.sh \
  --apps-domain apps.dflow.sh \
  --email ops@dflow.sh \
  --tunnel-token "$CLOUDFLARE_TUNNEL_TOKEN"
```

`DFLOW_TUNNEL_TOKEN` is the same token. The script installs `cloudflared` and runs `cloudflared service install`. It does not install the service again when `cloudflared` is already active. In the Cloudflare tunnel, route the API host and `*.<apps domain>` to `http://localhost:80`. There are no public A records. The script waits until those names resolve before it requests certificates. A worker join URL is not printed when there is no public IPv4; that does not fail the install.

### What the script changes

The script is safe to run again after the first run on this checkout. It installs k3s when k3s is missing, turns off ServiceLB, and puts Traefik on the host network so it binds ports 80 and 443 on every node (a DaemonSet). The DaemonSet rolls one node at a time with `maxUnavailable: 1`, so the old pod releases host ports 80 and 443 before the new one binds them. HTTP is not redirected to HTTPS, so cert-manager HTTP-01 can use port 80. The manifest is applied with server-side apply. When the file is unchanged and Traefik is already that DaemonSet, the script does not restart Traefik. It checks that Traefik's host IP is a node address, installs cert-manager, installs the dFlow chart, and installs the `dflow` CLI. A later run skips the server image build when k3s already has `dev-<git sha>`, and skips the CLI rebuild when that same checkout is already installed.

k3s is started with `cluster-init: true` (embedded etcd). A server that was installed earlier with SQLite restarts k3s once on the next run so the datastore can migrate. After that config is in place, a re-run does not restart k3s. See [Grow from one server to three](#grow-from-one-server-to-three).

When a GitHub Release exists, the script downloads the `dflow` CLI, the Helm chart package (`dflow-*.tgz`), and the server image `ghcr.io/dflow-sh/dflow-server:<tag>` from that release. The CLI download is checked against `checksums.txt` when that file is in the release. A checksum match and a binary that does not run are reported as separate lines. If the release cannot be downloaded, the script builds from the checkout and tags the server image `dev-<git sha>`. That build reports `v0.0.0-dev`. If the release download fails and the checkout build also fails, the script exits non-zero and names both failures. CI also uploads CLI binaries and a server image archive as workflow artifacts. That is not a production deploy.

The chart sets `server.defaultBuildMode` to `railpack`. A `dflow push` that omits `--build-mode` builds with Railpack (BuildKit in the staging job, image pushed to the in-cluster registry). `--build-mode buildpack` and `--build-mode dockerfile` stay explicit. `dflow app logs --staging` prints the staging pod name once, then left-aligned log lines. `--verbose` restores the pod and container prefix on every line.

When the script finishes it prints the API URL, the `admin` password, and the login command. It has already logged in, pushed `traefik/whoami`, required HTTP 200 from the app URL, deleted the app, and deleted the `sample` namespace. If any of those steps fail, the script exits non-zero and prints the step that failed.

Manual checks and uninstall: [docs/TESTING.md](TESTING.md).

The script also prints the k3s join URL and token, a worker command, and a `--control-plane` command for two more servers. The URL is `https://<first-server-public-ipv4>:6443`.

## Add a worker

Another Ubuntu 22.04 or 24.04 machine joins as a worker. Clone this private repository on that machine the same way as the first server (`GITHUB_TOKEN` for HTTPS, or a deploy key). The join command itself does not need a token beyond the k3s node token. Extra control-plane servers are a different command, described in [Grow from one server to three](#grow-from-one-server-to-three).

On the first server, `scripts/install.sh` prints the URL and token when it finishes. The URL is `https://<first-server-public-ipv4>:6443`. Read the token again from the k3s node-token file:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

`node-external-ip` in `/etc/rancher/k3s/config.yaml` is that public IPv4 when the address is configured on this host. When the detected address is only an egress NAT address, the field stays the IPv4 on the default route so the in-cluster API service still reaches this node. The join URL printed at the end still uses the public IPv4.

On the worker, from the checkout:

```bash
sudo ./scripts/join-node.sh \
  --server https://203.0.113.10:6443 \
  --token '<token printed by scripts/install.sh>'
```

Replace the IP and the token. The script installs the k3s agent and joins this host as a worker. Run it again with the same server and token and it leaves a healthy agent in place. A bad token, a server that does not answer `https://<ip>:6443/ping`, or a k3s agent that does not stay active exits non-zero and prints the reason. Do not run the worker command on a machine that already runs a k3s server.

On an existing server, confirm the worker:

```bash
sudo kubectl get nodes
```

`kubectl` as root uses `/etc/rancher/k3s/k3s.yaml`. The new node is listed `Ready`. That can take a minute after the agent starts. The worker's `ROLES` column is empty. A server started by `scripts/install.sh` is `control-plane,etcd`.

### Firewall

Allow these between every server and every worker:

| Port | Protocol | Where |
| --- | --- | --- |
| 6443 | TCP | nodes to any server (Kubernetes API) |
| 8472 | UDP | all nodes, both directions (flannel VXLAN) |
| 10250 | TCP | all nodes, both directions (kubelet) |

If `scripts/install.sh` logged that this kernel is using flannel host-gw, UDP 8472 is unused. Nodes still need a route to each other. Control-plane servers also need TCP 2379 and TCP 2380; that table is in the next section.

The scripts do not change host firewall rules. When `ufw` is enabled, on each node:

```bash
sudo ufw allow 6443/tcp
sudo ufw allow 8472/udp
sudo ufw allow 10250/tcp
```

## Grow from one server to three

`scripts/install.sh` writes `cluster-init: true` into `/etc/rancher/k3s/config.yaml` before k3s starts. That flag selects embedded etcd. A server installed from an older checkout that is still on SQLite picks the flag up the next time `scripts/install.sh` runs: k3s restarts once and migrates the datastore to etcd. One etcd member is a normal cluster. It is not highly available.

Etcd quorum is a majority. Three servers tolerate one failure. Two servers tolerate zero: if either stops, the cluster cannot elect a leader. Add the second and third servers together. Do not leave the cluster at two servers.

On each of two more Ubuntu 22.04 or 24.04 machines, from a checkout of this repository:

```bash
sudo ./scripts/join-node.sh \
  --server https://203.0.113.10:6443 \
  --token '<token printed by scripts/install.sh>' \
  --control-plane \
  --flannel-backend vxlan \
  --tls-san dflow.example.com \
  --tls-san apps.example.com
```

`--server` is the same API URL workers use. `--control-plane` installs a k3s server that joins the existing etcd. It does not pass `--cluster-init`. `--flannel-backend` must match `flannel-backend` in the first server's `/etc/rancher/k3s/config.yaml` (`vxlan` or `host-gw`). Repeat `--tls-san` for every name clients use to reach the Kubernetes API, including a load-balancer address if you add one. The script also adds this machine's default-route IPv4. `--node-external-ip` defaults to that same address. Set it only when the address is configured on a local interface. An egress NAT address in that field makes the in-cluster API service unroutable.

Run the command again with the same arguments and it leaves a healthy server in place. Do not run `--control-plane` on the machine that already has `cluster-init: true`.

Open these ports between the three servers, in addition to the worker ports above:

| Port | Protocol | Where |
| --- | --- | --- |
| 2379 | TCP | etcd client, every server to every other server |
| 2380 | TCP | etcd peer, every server to every other server |

```bash
sudo ufw allow 2379/tcp
sudo ufw allow 2380/tcp
```

Confirm on any server:

```bash
sudo kubectl get nodes
```

Three nodes should show `control-plane,etcd` and `Ready`. Workers, if any, have an empty `ROLES` column.

### API and app DNS

Traefik runs as a DaemonSet on the host network and listens on 80 and 443 on every node. Publish the API hostname and the apps wildcard with an A record (or AAAA) for each node that should receive traffic, or point both names at a TCP load balancer that forwards 80 and 443 to those nodes. A single address, including `<ip>.sslip.io`, reaches one host. If that host is down, the API and every app route are down even when etcd still has quorum.

Clients that talk to the Kubernetes API on port 6443 should use a name or load balancer that can reach any server, and that name must be a `--tls-san` on every server. Workers and extra servers can join through any server URL that answers `/ping`.

A Cloudflare Tunnel started by `scripts/install.sh` terminates on the first server only. It is not a multi-node ingress.

### dflow-server stays one replica

The chart sets `server.replicaCount` to 1 and rejects a higher count or `server.autoscaling.enabled`. The process is not stateless:

- Websocket tokens (staging logs, app shell) are signed with an RSA key generated in process memory at startup (`packages/dflow/helpers/authtoken/token.go`). A token created by one pod does not validate on another.
- Every API pod mounts `image-export-pvc`, which is `ReadWriteOnce`. A second pod stays Pending, and export jobs share that same claim with the API process that wrote the files. Required anti-affinity across nodes cannot be combined with that volume.
- Helm installs are serialized with an in-process mutex (`packages/dflow/helm/client.go`). Two pods can upgrade the same release at the same time.

User records and application objects already live in Kubernetes. That does not make a second API pod safe. There is no PodDisruptionBudget and no anti-affinity on `dflow-server`, because those objects only help when more than one pod can run. The image-export volume is local to one node, so that single pod does not move to another node while the volume is there.

### Registry and SeaweedFS

The in-cluster registry is one pod (`packages/helm-chart/templates/container-registry/container-registry.yaml`). By default its storage is an `emptyDir`, which is deleted when the pod is rescheduled. Two registry pods would not replicate blobs. To keep images across a node loss, set `containerregistry.enabled` to false and set `global.registryURL`, `global.registryUsername`, `global.registryPassword`, and `global.registryNamespace` to an external registry.

SeaweedFS is the S3 store for source uploads. The chart leaves master, volume, and filer at one replica. The upstream master pods already request hostname anti-affinity, and the masters need a majority to elect a leader, so raising `seaweedfs.master.replicas` on a one-node cluster leaves S3 down. After three servers are `Ready`, a Helm upgrade can set:

```yaml
seaweedfs:
  global:
    enableReplication: true
    replicationPlacement: "001"
  master:
    replicas: 3
  volume:
    replicas: 3
  filer:
    replicas: 2
    defaultReplicaPlacement: "001"
```

`001` keeps one extra copy on another server. Master data in the upstream chart defaults to a hostPath. Give each master its own disk before raising the replica count. Do this only when three nodes can schedule the anti-affinity rule.

## macOS CLI

Go 1.26 is required. From a checkout on the Mac:

```bash
make dflow
sudo install -m 0755 dist/dflow /usr/local/bin/dflow
dflow version
dflow login -u admin -p 'password' --trust-ca "https://dflow.<domain>"
```

`<domain>` and the password are what `scripts/install.sh` printed. `password` is the default. Drop `--trust-ca` when the installer used Let's Encrypt production (`letsencrypt-production`). Keep it for `dflow-ca` and for `letsencrypt-staging`.

The same push as the server self-test. `traefik/whoami` listens on `WHOAMI_PORT_NUMBER`, which defaults to 80. The app chart routes to port 8080, so the push sets that variable:

```bash
dflow namespace create sample
dflow target sample
dflow push -n hello --container-image-url traefik/whoami -e WHOAMI_PORT_NUMBER=8080
curl -k -sS -D - "https://hello.<domain>/" -o /tmp/whoami-body | head -n 1
dflow app delete hello
dflow namespace delete sample -f
```

Drop `-k` when the certificate is Let's Encrypt production. Expected: login prints `Login successful`, push prints `App is online.` and `https://hello.<domain>`, curl prints `HTTP/2 200` or `HTTP/1.1 200 OK`, delete prints `Applications Removed.` A source push with no `--build-mode` uses railpack. Pass `--build-mode buildpack` or `--build-mode dockerfile` to select those builders.

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
gh run list --repo dflow-sh/kube-poc --branch main --workflow ci --limit 1
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

A Mac installs or replaces the CLI with `scripts/install-cli.sh`, not with `scripts/update.sh`.

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
- a public IPv4 address, or a Cloudflare Tunnel token when the host has none
- root SSH
- a DNS name for the API and for apps, unless you use sslip.io

DNS is either names you control, or [sslip.io](https://sslip.io).

Split names, public IP `203.0.113.10`:

- `A` `paas.example.com` → `203.0.113.10`
- `A` `*.apps.example.com` → `203.0.113.10`
- the API is `https://paas.example.com`
- an app named `hello` is `https://hello.apps.example.com` (`dflow target` selects the namespace; the hostname does not include it)
- pass `--api-domain paas.example.com --apps-domain apps.example.com --email you@example.com`

One wildcard, same IP, `--domain apps.example.com`:

- `apps.example.com` and `*.apps.example.com` both point at `203.0.113.10`
- the API is `https://dflow.apps.example.com`
- an app named `hello` is `https://hello.apps.example.com`

sslip.io needs no DNS account. With the same IP and `--domain auto`:

- domain `203.0.113.10.sslip.io`
- API `https://dflow.203.0.113.10.sslip.io`
- apps `https://<app>.203.0.113.10.sslip.io`
- the certificate is the internal dFlow CA

`sslip.io` answers for that name and for `*.203.0.113.10.sslip.io`.

Change the default admin password before the host is reachable on the internet. The chart default user is `admin` / `password`.

## Tools on the machine

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Go 1.26 is required only to build the server image. Unreleased builds use `ghcr.io/dflow-sh/dflow-server:v0.0.0-dev`. A release tag replaces that tag in the packaged chart. Build the image on the machine (next section) or use the image from the release.

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
docker build -f images/Dockerfile -t ghcr.io/dflow-sh/dflow-server:v0.0.0-dev .
docker save ghcr.io/dflow-sh/dflow-server:v0.0.0-dev | sudo k3s ctr images import -
```

If Docker is not installed, `sudo apt-get install -y docker.io` and start the daemon. k3s uses containerd, so the image has to be imported with `k3s ctr`. Pulling from a registry you pushed the same tag to also works. The chart sets `image.pullPolicy` to `IfNotPresent`, so a node that already has the image does not try the registry.

The image entrypoint is the `dflow` CLI. The chart runs `/dflow server`.

## 3. Install the chart

The chart installs, when you turn the switches on:

- cert-manager (the bundled chart, installed first so its CRDs exist)
- the container registry (`containerregistry.enabled`, default true)
- S3-compatible storage via SeaweedFS (`seaweedfs.enabled`, default true)
- railpack as the default builder (`server.defaultBuilderImage`, reported by `/info` as `default_builder_image`)
- the Paketo builder image reference (`image.builder`, `paketobuildpacks/builder-jammy-full`), used when `--build-mode buildpack` passes a builder image
- the Railpack BuildKit image (`image.railpack`, `moby/buildkit`), used when a push omits `--build-mode` (`server.defaultBuildMode: railpack`)

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

# container image: no builder. whoami must listen on 8080.
dflow push -n hello --container-image-url traefik/whoami -e WHOAMI_PORT_NUMBER=8080

dflow app list
dflow app logs hello
dflow app delete hello
```

`dflow app logs` without `--follow` prints the current logs and returns. Add `--follow` to stream.

A source push with no `--build-mode` uses railpack. The server default is `server.defaultBuildMode` (`railpack` in the chart). Pass a mode to override it:

```bash
dflow push -n hello -p assets/sample-app
dflow push -n hello -p assets/sample-app --build-mode buildpack
dflow push -n hello -p assets/sample-app --build-mode dockerfile
```

`dflow app logs --staging hello` prints the staging pod once, then the log text. Add `--verbose` on `push` or `app logs` to put the pod and container name on every line.

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
