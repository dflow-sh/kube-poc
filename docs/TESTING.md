# Test dFlow on the server

Run `scripts/install.sh` first. It already logs in, pushes `traefik/whoami`, checks that the app URL returns HTTP 200, deletes the app, and deletes the `sample` namespace. The commands below repeat that check by hand, then scale, set an environment variable, and reset the machine.

Set `DOMAIN` to the domain the installer printed. For a public IP `203.0.113.10` chosen automatically, that is `203.0.113.10.sslip.io`. The API is `https://dflow.203.0.113.10.sslip.io`. An app named `hello` is `https://hello.203.0.113.10.sslip.io`. The namespace is not part of the hostname.

The default user is `admin`. The default password is `password` unless you passed `--admin-password`. With `--domain auto` the API certificate is the dFlow CA, so login uses `--trust-ca` and curl uses `-k`. A custom domain uses Let's Encrypt production: drop `--trust-ca` and `-k`. `--letsencrypt-staging` still needs them.

```bash
export DOMAIN=203.0.113.10.sslip.io
export PASSWORD=password
```

## Login

```bash
dflow login -u admin -p "$PASSWORD" --trust-ca "https://dflow.${DOMAIN}"
```

Expected:

```text
Login to your dFlow cluster [https://dflow.203.0.113.10.sslip.io]
Trusting certificate for address https://dflow.203.0.113.10.sslip.io...
Login successful
```

The CLI prints a ship mark on the login line and a check mark on the success lines.

## Push a sample app

```bash
dflow namespace create sample
dflow target sample
dflow push -n hello --container-image-url traefik/whoami -e WHOAMI_PORT_NUMBER=8080
```

`namespace create` prints `Namespace created.`

`target` prints `Targeting namespace...` and `Namespace targeted.`

`push` prints the app name `hello`, source origin `traefik/whoami`, and asks you to press Enter. It continues on its own after 5 seconds. It then prints `Create the application resource ...`, `Building and deploying application on the server ...`, and:

```text
Name: hello
Namespace: sample
App is online.
1: https://hello.203.0.113.10.sslip.io
```

The route line is `https://hello.${DOMAIN}`.

If `sample` already exists, `namespace create` fails. Run `dflow target sample` and continue with `push`.

## List

```bash
dflow app list
```

Expected: a table whose header is `NAME`, `CREATED`, `STATUS`, `ROUTES`, `CONFIGURATIONS`, `STATUS DETAILS`. The `hello` row has status `1/1` and route `hello.${DOMAIN}`.

## Logs

```bash
dflow app logs hello
```

Expected: `Streaming application logs`, then one or more lines. A `traefik/whoami` container started with `WHOAMI_PORT_NUMBER=8080` includes `Starting up on port 8080`. The app chart routes to port 8080, so the sample push sets that variable. Without it, whoami listens on port 80 and the route returns 502. The command prints the current logs and returns. `--follow` streams and does not return.

Staging logs (`dflow app logs --staging hello`, and the log stream during `dflow push`) print the long stage pod name once, then left-aligned lines. `--verbose` on `push` or `app logs` puts the pod and container name back on every line.

## Open the URL

```bash
curl -k -sS -D - "https://hello.${DOMAIN}/" -o /tmp/whoami-body | head -n 1
echo
head -n 20 /tmp/whoami-body
```

Expected status line:

```text
HTTP/2 200
```

Some paths show `HTTP/1.1 200 OK`. Either 200 is success. The body contains `Hostname:` and `GET / HTTP/1.1`, and the `Host` line is `hello.${DOMAIN}`.

## Scale

```bash
dflow app update hello -i 2
```

Expected:

```text
Update application
Namespace: sample
Application: hello
Successfully updated application
```

Wait until the new pod is up, then list again:

```bash
dflow app list
```

Expected status: `2/2`.

## Environment variable

```bash
dflow app env set hello SAMPLE_GREETING hello-dflow
```

Expected:

```text
Extend or modify application environment
Namespace: sample
Application: hello
Variable: SAMPLE_GREETING
Value: hello-dflow
OK
```

The app restarts. Repeat the curl until the body contains:

```text
SAMPLE_GREETING=hello-dflow
```

## Delete

```bash
dflow app delete hello
dflow app list
```

`delete` prints `Deleting Applications...` and `Applications Removed.`

`list` prints `Listing applications` and a table with the header row and no `hello` row.

```bash
dflow namespace delete sample -f
```

Expected: `Deleting namespaces...` and `Namespaces deleted.`

```bash
dflow namespace list
```

`sample` is not in the list.

## Source push and build mode

Railpack is the default. A push that does not pass `--build-mode` stores `railpack` on the app and the staging job runs the railpack script. Buildpack and Dockerfile stay available as explicit flags.

```bash
dflow push -n node-app -p /path/to/node-app
dflow app show node-app
dflow app logs --staging node-app
```

`app show` includes `buildmode: railpack` (or the JSON field `buildmode`). The staging log names railpack and BuildKit, and the app route returns HTTP 200 after the image is pushed to the in-cluster registry.

The same tree with the Paketo builder:

```bash
dflow app delete node-app
dflow push -n node-app -p /path/to/node-app --build-mode buildpack
dflow app show node-app
```

That app's `buildmode` is `buildpack`. An existing app keeps the build mode stored on its spec when a later push omits `--build-mode`. Delete it, or pass the flag, to change the mode. `--build-mode dockerfile` uses the Dockerfile in the source tree.

## Worker node

On an existing server, after `scripts/join-node.sh` on another Ubuntu machine:

```bash
sudo kubectl get nodes
```

The new node is `Ready`. Its `ROLES` column is empty. A server started with `scripts/install.sh` is `control-plane,etcd`. The join URL and token are what `scripts/install.sh` printed (`https://<first-server-public-ipv4>:6443` and the k3s node token). Firewall ports are TCP 6443, UDP 8472, and TCP 10250. Details are in [docs/INSTALL.md](INSTALL.md).

## Three control-plane servers

This needs two more Ubuntu machines. It is not a check you can finish on the first server alone.

On each new machine:

```bash
sudo ./scripts/join-node.sh \
  --server https://<first-server-public-ipv4>:6443 \
  --token '<token>' \
  --control-plane \
  --flannel-backend <vxlan-or-host-gw> \
  --tls-san <api-host>
```

Then, on any server:

```bash
sudo kubectl get nodes
sudo kubectl -n kube-system get ds traefik
sudo kubectl -n dflow get deploy dflow-server
```

Expected: three nodes with `control-plane,etcd` and `Ready`. Traefik is a DaemonSet with a host-network pod on each node. `dflow-server` still has `1` available replica. The chart rejects `server.replicaCount` greater than 1. Registry and SeaweedFS stay one replica until you follow the external-registry and SeaweedFS steps in [docs/INSTALL.md](INSTALL.md). API and app DNS should list every Traefik node, or a load balancer in front of them.

## Uninstall and reset

This removes dFlow, cert-manager, and k3s from the server. It deletes cluster data under `/var/lib/rancher/k3s`.

```bash
sudo helm uninstall dflow -n dflow
sudo helm uninstall cert-manager -n cert-manager
sudo k3s-uninstall.sh
sudo rm -f /usr/local/bin/dflow
sudo rm -rf /var/lib/dflow /etc/rancher/k3s /var/lib/rancher/k3s
rm -f "${HOME}/.config/dflow/settings.yaml"
```

`k3s-uninstall.sh` is installed by k3s at `/usr/local/bin/k3s-uninstall.sh`. After it runs, `kubectl get nodes` fails because the API is gone.

To install again, clone is already on disk:

```bash
sudo ./scripts/install.sh --domain auto
```
