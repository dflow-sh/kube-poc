# Install dFlow

dFlow runs on Kubernetes. The chart does not install a UI. `dflowUI.enabled` is false.

## Known limits

- The registry uses emptyDir storage, so images are lost when the pod restarts. `containerregistry.storage.emptyDir=false` uses a PVC.
- local-path volumes are tied to one server.
- There is no node replacement or backup procedure yet.
- Builds run privileged.
- Accepted CVEs: Reflector CVE-2026-70188 and CVE-2026-88092, kaniko CVE-2025-68121 and CVE-2026-33186.
- The CLI is the only interface.
- Apps must listen on 8080, or set `-v appListeningPort=<port>` (short for `--chart-value`) on `dflow push`, `dflow app create`, and `dflow app update`.
- A push through the registry NodePort 30500 nginx returns 413 when the body exceeds 1 MB. That nginx has no `client_max_body_size`, so the 1 MB default applies. In-cluster builds are not affected.
- The registry on NodePort 30500 is plain HTTP on the public IP.
- `dflow app exec` needs bash in the image.
- `dflow app port-forward` does not work yet.
- App namespaces get no Pod Security labels, NetworkPolicy, or quotas, so there is no tenant isolation.
- The chart seeds users `admin` and `dflow`. There is no user command and no sign-up command. An OIDC login can create a user by email.
- `dflow upgrade` downloads a public GitHub release. The server step runs helm on a machine that can read the cluster kubeconfig. On the server that file is `/etc/rancher/k3s/k3s.yaml`.
- `dflow login --oidc` opens a browser. The acceptance suite checks the authorization-code prompt against Dex, not that browser callback.

## Install the CLI

On macOS or Linux, with no clone:

```bash
curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh
```

The file in this repository is `scripts/cli/install.sh`. The release publishes that same file as `install.sh`. The download sends no token. The script selects `linux` or `darwin` and `amd64` or `arm64`, downloads `dflow-<os>-<arch>` from the same public release, and checks SHA256 against `checksums.txt`. A missing asset, a missing checksum line, or a checksum mismatch exits non-zero.

```bash
curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh -s -- --version vX.Y.Z
curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh -s -- --install-dir "$HOME/.local/bin"
```

`--version` is a release tag, or `latest` (the default). `--install-dir` is the destination directory. `DFLOW_VERSION` and `DFLOW_INSTALL_DIR` set those same values when the flags are omitted.

`/usr/local/bin` is used when that directory is writable or `sudo -n` succeeds. If it is not writable, passwordless sudo is unavailable, and `/dev/tty` can be read, the script asks before running sudo. The question and the sudo password are read from `/dev/tty`, which still works under `curl | sh`. Declining, or running with no terminal, installs to `~/.local/bin` and prints a PATH hint. A second run replaces the binary. If `dflow` on `PATH` is a different file from the one just installed, the script prints both paths.

The script then runs `dflow version` and prints the next step, `dflow login`. `dflow login` requires the API URL. `-u` / `--user` and `-p` / `--password` set the admin user and password. `--trust-ca` trusts an unknown certificate:

```bash
dflow login -u admin -p '<password>' --trust-ca "https://dflow.<domain>"
```

Omit `--trust-ca` when the API certificate is already trusted. `dflow upgrade --cli-only` replaces the CLI from a later public release and does not change the cluster. `dflow upgrade` also accepts `--version`, `--server-only`, and `--dry-run`. Those flags are in this tree (`packages/dflow/cli/cmd/upgrade.go`). The published `v0.0.4` binary does not include `dflow upgrade`.

`install.sh` is not on the `v0.0.4` release. The `releases/latest/download/install.sh` URL works once a release that contains this script is published. Until then, the four `dflow-<os>-<arch>` binaries and `checksums.txt` from `v0.0.4` are the public CLI download.

From a checkout, `./scripts/install-cli.sh` still installs the CLI and, when `--api` is set, logs in and runs the sample push. See [scripts/install-cli.sh](#scriptsinstall-clish).

## One-shot install on Ubuntu

The repository is public. Clone it, then run the installer from that checkout.

The server is Ubuntu 22.04 or 24.04, with at least 8 GB RAM, a public IPv4 address, and root SSH.

```bash
git clone https://github.com/dflow-sh/kube-poc.git
cd kube-poc
sudo ./scripts/install.sh --domain auto
```

Release assets (the CLI, `checksums.txt`, and the Helm chart package) are downloaded from this repository's GitHub Releases. The download does not send a token. `ghcr.io/dflow-sh/dflow-server` is pulled without a registry login. A pull that fails is an error: the script prints the registry output and exits. It does not reuse a checkout image and it does not build one. `--from-checkout` is the only checkout build.

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

The script is safe to run again after the first run on this checkout. It installs k3s when k3s is missing, turns off ServiceLB, and puts Traefik on the host network so it binds ports 80 and 443 on every node (a DaemonSet). The DaemonSet rolls one node at a time with `maxUnavailable: 1`, so the old pod releases host ports 80 and 443 before the new one binds them. HTTP is not redirected to HTTPS, so cert-manager HTTP-01 can use port 80. The manifest is applied with server-side apply. When the file is unchanged and Traefik is already that DaemonSet, the script does not restart Traefik. It checks that Traefik's host IP is a node address, installs cert-manager, installs the dFlow chart, and installs the `dflow` CLI. After the k3s API answers, it waits until a node object exists and that node is Ready before it waits on Traefik, cert-manager, or dflow-server. An empty node list is not treated as ready. With `--from-checkout`, a later run skips the server image build when k3s already has `dev-<git sha>`, and skips the CLI rebuild when that same checkout is already installed.

k3s is started with `cluster-init: true` (embedded etcd). A server that was installed earlier with SQLite restarts k3s once on the next run so the datastore can migrate. After that config is in place, a re-run does not restart k3s. See [Grow from one server to three](#grow-from-one-server-to-three).

When a GitHub Release exists, the script downloads the `dflow` CLI and the Helm chart package (`dflow-<version>.tgz`) from that release, and pulls the server image `ghcr.io/dflow-sh/dflow-server:<tag>`. The CLI download is checked against `checksums.txt`. A missing checksum, a checksum mismatch, a binary that does not run, or a server image that cannot be pulled exits non-zero. The script does not build this checkout in those cases. `--version vX.Y.Z` selects that release instead of the latest one. `--from-checkout` builds the CLI and tags the server image `dev-<git sha>`. That build reports `v0.0.0-dev`. CI also uploads CLI binaries and a server image archive as workflow artifacts. That is not a production deploy.

The chart sets `server.defaultBuildMode` to `railpack`. A `dflow push` that omits `--build-mode` builds with Railpack (BuildKit in the staging job, image pushed to the in-cluster registry). `--build-mode buildpack` and `--build-mode dockerfile` stay explicit. `dflow app logs --staging` prints the staging pod name once, then left-aligned log lines. `--verbose` restores the pod and container prefix on every line.

When the script finishes it prints the API URL, the `admin` password, and the login command. It has already logged in, pushed `traefik/whoami` as `dflow-install-check`, required HTTP 200 from that app URL, deleted that app, and deleted the `dflow-install-check` namespace. If an app already uses that name, or an ingress already serves `dflow-install-check.<domain>`, the push is skipped and the existing app is left in place. If any other step fails, the script exits non-zero and prints the step that failed.

Manual checks and uninstall: [docs/TESTING.md](TESTING.md).

The script also prints the k3s join URL and token, a worker command, and a `--control-plane` command for two more servers. The URL is `https://<first-server-public-ipv4>:6443`.

## Add a worker

Another Ubuntu 22.04 or 24.04 machine joins as a worker. Clone this repository on that machine the same way as the first server. The join command itself does not need a token beyond the k3s node token. Extra control-plane servers are a different command, described in [Grow from one server to three](#grow-from-one-server-to-three).

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

SeaweedFS is the S3 store for source uploads. With `seaweedfsIngressPolicy.enabled` left at its default, the chart installs NetworkPolicies for the master, volume, filer, and S3 pods. Master, volume, and filer accept ingress only from other SeaweedFS pods in the release. The S3 API port accepts ingress from `dflow-server` and from staging pods that download source blobs. The filer gRPC port stays closed to those clients. The in-cluster registry stores images on its own volume and is not an S3 client. Set `seaweedfsIngressPolicy.enabled` to false to skip the policies. k3s applies them with its default network policy controller.

The chart leaves master, volume, and filer at one replica. The upstream master pods already request hostname anti-affinity, and the masters need a majority to elect a leader, so raising `seaweedfs.master.replicas` on a one-node cluster leaves S3 down. After three servers are `Ready`, a Helm upgrade can set:

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

### Pod Security

Platform containers set resource requests and limits, `seccompProfile: RuntimeDefault`, and `capabilities.drop: [ALL]`. Dex, reflector, the registry (nginx and registry), helm-controller, dflow-server, the CRD upgrade Job, and dflow-ui (when enabled) also set `runAsNonRoot`, `allowPrivilegeEscalation: false`, and `readOnlyRootFilesystem: true`.

Two exceptions stay in `packages/helm-chart/values.yaml`:

- SeaweedFS master, volume, filer, and S3 keep hostPath volumes. hostPath fails PodSecurity baseline, so those pods are not baseline and not restricted. `runAsNonRoot` is omitted because the host directories are root-owned. `readOnlyRootFilesystem` is omitted because weed writes that data and those logs.
- Staging builds are not platform containers. Railpack runs privileged because BuildKit's OCI worker needs nested containers. Buildpack runs as the application uid and gid. Dockerfile mode sets no security context. A restricted context on those jobs would break builds.

## macOS CLI

Go 1.26 is required. From a checkout on the Mac:

```bash
make dflow
sudo install -m 0755 dist/dflow /usr/local/bin/dflow
dflow version
dflow login -u admin -p '<admin-password>' --trust-ca "https://dflow.<domain>"
```

`<domain>` and the admin password are what `scripts/install.sh` printed. The password is random unless you passed `--admin-password`. Read it again with `kubectl -n dflow get secret dflow-generated-passwords -o jsonpath='{.data.adminPassword}' | base64 -d`. Drop `--trust-ca` when the installer used Let's Encrypt production (`letsencrypt-production`). Keep it for `dflow-ca` and for `letsencrypt-staging`.

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

CI on this branch uploads `dflow-darwin-arm64` and `dflow-darwin-amd64` as workflow artifacts. From a checkout of the default branch:

```bash
gh run list --repo dflow-sh/kube-poc --branch main --workflow ci --limit 1
gh run download --repo dflow-sh/kube-poc <run-id> -n dflow-darwin-arm64
sudo install -m 0755 dflow-darwin-arm64 /usr/local/bin/dflow
```

A published release is the install path below. Building locally does not wait on that artifact.

### scripts/install-cli.sh

From a Mac or Linux checkout, this installs the matching binary to `/usr/local/bin/dflow`, then logs in and runs the sample push when `--api` is set.

```bash
./scripts/install-cli.sh \
  --api "https://dflow.<domain>" \
  --user admin \
  --password '<admin-password>'
```

`<domain>` and the admin password are what `scripts/install.sh` printed on the server. `--user` and `--password` are `dflow login -u` and `-p`. The script downloads `dflow-darwin-arm64`, `dflow-darwin-amd64`, `dflow-linux-arm64`, or `dflow-linux-amd64` from the public GitHub Release and requires a matching line in `checksums.txt`. If that asset cannot be downloaded, the script exits non-zero. `--from-checkout` runs `go build` from the checkout (Go 1.26). `--version vX.Y.Z` selects that tag instead of the latest release.

To check a release, download `checksums.txt` and `checksums.txt.sigstore.json`. Verify that signature, then check the chart tarball, `install.sh`, and the CLI binaries against `checksums.txt`. Those files do not have their own `.sigstore.json`. cosign 3.1.4 `verify-blob` takes `--bundle`, `--certificate-identity`, and `--certificate-oidc-issuer` (there is no separate certificate flag). The identity is this repository's release workflow at the tag, and the issuer is GitHub Actions OIDC:

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

That checks the signature on `checksums.txt`. The chart tarball and `install.sh` are lines in that file. They do not have their own `.sigstore.json`. After the signature check, use `sha256sum` on Linux or `shasum` on macOS:

```bash
sha256sum -c checksums.txt --ignore-missing
shasum -a 256 -c checksums.txt --ignore-missing
```

Verify the server image with `cosign verify` (not `verify-blob`) and the same identity. `cosign sign` in the release workflow uses `--yes` and `--oidc-provider=github-actions` and signs `${artifact}@${digest}`. That signature exists only after the `v*` workflow runs, so the image check is proven when `v0.1.0` is tagged.

```bash
cosign verify \
  --certificate-identity "https://github.com/dflow-sh/kube-poc/.github/workflows/release.yml@refs/tags/${tag}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  "ghcr.io/dflow-sh/dflow-server:${tag}"
```

Without `--api` the binary is still installed and the script prints the login and push commands instead of running them.

On macOS, a browser download can be quarantined. If Gatekeeper refuses to run the binary:

```bash
xattr -d com.apple.quarantine /usr/local/bin/dflow
```

A binary installed by `scripts/install-cli.sh` or `install -m 0755` is not quarantined. A binary saved from a browser is.

## Upgrade

On the server, after the one-shot install, either command upgrades the CLI and then the server to the same release:

```bash
sudo dflow upgrade
sudo ./scripts/update.sh
```

`dflow upgrade` downloads the CLI from the public release, checks SHA256, and replaces the running binary. A permission error prints a `sudo dflow upgrade` line and does not change the server. It then runs `helm upgrade --install dflow` with the chart package from that release (`dflow-<version>.tgz`), sets `image.dflow.tag`, imports `ghcr.io/dflow-sh/dflow-server:<tag>` when `docker` and `k3s` are on the machine, and waits until `dflow-server` is ready.

```bash
sudo dflow upgrade --version vX.Y.Z
sudo dflow upgrade --cli-only
sudo dflow upgrade --server-only
sudo dflow upgrade --dry-run
```

`--dry-run` prints the asset URL and the helm command. `--cli-only` does not touch the cluster. `--server-only` does not replace the CLI.

`dflow upgrade` does not install k3s, cert-manager, or Traefik, and does not run the login and sample-push self-test. A saved admin password other than `password` or `changeme` is left unchanged. Those two old defaults are replaced. Dex is restarted, and the command prints the `kubectl` command that reads the new password from Secret `dflow-generated-passwords`. It does not print the password. When the Dex checksum annotation is missing, Dex is restarted so it loads the current password. A machine that cannot read `/etc/rancher/k3s/k3s.yaml` (or `KUBECONFIG`) stops after the CLI step and tells you to run `sudo ./scripts/update.sh <tag>` on the server.

`scripts/update.sh` replaces `/usr/local/bin/dflow` from the same release, then runs the helm upgrade, waits until `dflow-server` is ready, and repeats the API health check and the CLI self-test (login, push `traefik/whoami` as `dflow-install-check`, curl expecting HTTP 200, delete, confirm that namespace is gone). A saved admin password of `password` or `changeme` is replaced. The script prints the `kubectl` command that reads the new password from Secret `dflow-generated-passwords` and does not print the password. An existing app on another name, including `hello.<domain>`, is left in place. If `dflow-install-check` or its route is already in use, the smoke push is skipped and that app is left in place.

```bash
sudo ./scripts/update.sh v0.0.4
```

If that tag does not exist, the script stops. It does not build a different commit and label it with the missing tag. If the server image for that release cannot be pulled, the script stops. It does not reuse an image already imported from this checkout. If no latest release exists, the script stops unless you pass `--from-checkout`. That flag builds from the checkout, tags the image `dev-<git sha>`, upgrades with that image, and still runs the self-test.

`dflow client-sync` still only replaces the CLI so it matches the server you are logged in to. It uses the same public URL, asset name, and `checksums.txt` check. It does not upgrade the server.

## Release assets

`.github/workflows/release.yml` runs only when a tag matching `v*` is pushed. For example `v0.0.4`. It uses GoReleaser. The tag must point at a commit that already contains that workflow file. Pushing the tag is the only trigger. Do not run it by hand from a pull request.

```bash
git checkout main
git pull
git tag v0.0.4
git push origin v0.0.4
```

The workflow then:

- publishes `install.sh`, `dflow-linux-amd64`, `dflow-linux-arm64`, `dflow-darwin-amd64`, and `dflow-darwin-arm64`, plus `checksums.txt`, as GitHub Release assets
- fails the release job if `install.sh` cannot be downloaded with no token, or if those bytes differ from `scripts/cli/install.sh`
- pushes `ghcr.io/dflow-sh/dflow-server:<tag>` and `ghcr.io/dflow-sh/dflow-server:latest`
- packages the Helm chart and uploads `dflow-<version>.tgz` (tag `v0.0.4` uploads `dflow-0.0.4.tgz`) on the same release

Actions uses the workflow `GITHUB_TOKEN` (`contents: write` and `packages: write`) to publish. Downloading those assets does not need a token.

```text
https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/install.sh
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/dflow-<os>-<arch>
https://github.com/dflow-sh/kube-poc/releases/download/<tag>/checksums.txt
```

For tag `v0.0.4` the linux/amd64 file is `dflow-linux-amd64`. `checksums.txt` is the sibling file. The lines look like `<sha256>  dflow-linux-amd64`. That tag does not include `install.sh`. [Install the CLI](#install-the-cli) is the install path on a release that publishes it.

The same binary and checksum can be checked by hand:

```bash
curl -fsSL -o dflow-linux-amd64 \
  https://github.com/dflow-sh/kube-poc/releases/download/v0.0.4/dflow-linux-amd64
curl -fsSL -o checksums.txt \
  https://github.com/dflow-sh/kube-poc/releases/download/v0.0.4/checksums.txt
grep ' dflow-linux-amd64$' checksums.txt | sha256sum -c -
sudo install -m 0755 dflow-linux-amd64 /usr/local/bin/dflow
```

On macOS, clear the quarantine attribute when the binary was saved by a browser (`xattr -d com.apple.quarantine /usr/local/bin/dflow`).

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

The installer generates the admin password and stores it in Secret `dflow-generated-passwords`. A second run keeps that value. A saved `ADMIN_PASSWORD` of `password` or `changeme` is an old default: `scripts/install.sh` and `scripts/update.sh` replace it, print a warning, and the old password stops working. Pass `--admin-password` to set or rotate it. The installer sets a checksum annotation on Dex to the sha256 of the admin password's bcrypt hash, so the Deployment rolls when that hash changes. The `dflow` user is the `dflowPassword` key in the same Secret. Dex users `admin@dflow.sh` and `dflow@dflow.sh` use those two passwords. The registry password is the `registryPassword` key in the same Secret. `changeme` is not a registry password. NodePort 30500 uses the generated value. Pass `--registry-password` to set or rotate it. `helm uninstall` leaves Secret `dflow-generated-passwords` in place.

## Tools on the machine

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Go 1.26 is required only to build the server image. Unreleased builds use `ghcr.io/dflow-sh/dflow-server:v0.0.0-dev`. A release tag replaces that tag in the packaged chart. `scripts/install.sh --from-checkout` builds that image. The manual steps in the next sections do the same build without the script. A release install pulls `ghcr.io/dflow-sh/dflow-server:<tag>` instead.

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
# https://go.dev/dl/go1.26.10.linux-amd64.tar.gz
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
- the Railpack BuildKit image (`image.railpack`), used when a push omits `--build-mode` (`server.defaultBuildMode: railpack`)

No Paketo builder image is installed. Buildpack mode needs a builder image passed with the push. MinIO is not installed. To use another S3 store, set `seaweedfs.enabled=false` and set `s3.endpoint`, `s3.accessKeyID`, `s3.secretAccessKey`, and `s3.bucket`.

Platform images are digest-pinned to their upstream registries. Development catalog entries still name Bitnami chart repositories. `install.sh` does not pull those.

Install cert-manager from the chart bundled in this repo, then dFlow. The dFlow manifests include `Certificate` resources, so the cert-manager CRDs have to exist before that install. The cert-manager version is the dependency in `packages/helm-chart/Chart.yaml`. The checkout vendors one `charts/cert-manager-*.tgz`, and the commands below use that glob.

```bash
export DOMAIN=203.0.113.10.sslip.io   # or apps.example.com

helm upgrade --install cert-manager packages/helm-chart/charts/cert-manager-*.tgz \
  --namespace cert-manager --create-namespace \
  --values packages/helm-chart/cert-manager-images.yaml \
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
helm upgrade --install cert-manager packages/helm-chart/charts/cert-manager-*.tgz \
  --namespace cert-manager --create-namespace \
  --values packages/helm-chart/cert-manager-images.yaml \
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
