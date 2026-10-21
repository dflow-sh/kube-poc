# Test dFlow on the server

Run `scripts/install.sh` first. It already logs in, pushes `traefik/whoami`, checks that the app URL returns HTTP 200, deletes the app, and deletes the `sample` namespace. The commands below repeat that check by hand, then scale, set an environment variable, and reset the machine.

Set `DOMAIN` to the domain the installer printed. For a public IP `203.0.113.10` chosen automatically, that is `203.0.113.10.sslip.io`. The API is `https://dflow.203.0.113.10.sslip.io`. An app named `hello` is `https://hello.203.0.113.10.sslip.io`. The namespace is not part of the hostname.

The default user is `admin`. The default password is `password` unless you passed `--admin-password`. The API certificate is the dFlow CA, so login uses `--trust-ca` and curl uses `-k`.

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
dflow push -n hello --container-image-url traefik/whoami
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

Expected: `Streaming application logs`, then one or more lines. A `traefik/whoami` container includes `Starting up on port 80`. The command prints the current logs and returns. `--follow` streams and does not return.

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
