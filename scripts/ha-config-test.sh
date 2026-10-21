#!/usr/bin/env bash
# Render checks for the first-server etcd config, the control-plane join
# config, and the chart rule that keeps dflow-server at one replica.
# Does not install k3s and does not write /etc/rancher/k3s.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "ha-config-test: $*" >&2
  exit 1
}

# shellcheck disable=SC1091
source scripts/install.sh
# shellcheck disable=SC1091
source scripts/join-node.sh

NODE_IP="10.0.0.10"
PUBLIC_IP="203.0.113.10"
API_HOST="dflow.example.com"
APPS_BASE="apps.example.com"
FLANNEL_BACKEND="vxlan"

server_cfg="$(k3s_server_config_body)"
grep -q '^cluster-init: true$' <<<"$server_cfg" || fail "first server config missing cluster-init"
grep -q '^node-external-ip: 10.0.0.10$' <<<"$server_cfg" || fail "non-local public IP was written as node-external-ip"
grep -q '^flannel-backend: vxlan$' <<<"$server_cfg" || fail "flannel backend missing"
if grep -Eq '^server:' <<<"$server_cfg"; then
  fail "first server config must not set a join server URL"
fi

PUBLIC_IP="10.0.0.10"
# ip_is_local is false for this address on a machine that does not own it.
# When the test host does own 10.0.0.10, skip the positive local case.
if ip_is_local "10.0.0.10"; then
  local_cfg="$(k3s_server_config_body)"
  grep -q '^node-external-ip: 10.0.0.10$' <<<"$local_cfg" || fail "local public IP was not used as node-external-ip"
fi
PUBLIC_IP="203.0.113.10"

traefik="$(traefik_helmchartconfig_body)"
grep -q 'kind: DaemonSet' <<<"$traefik" || fail "Traefik config is not a DaemonSet"
grep -q 'maxUnavailable: 1' <<<"$traefik" || fail "Traefik rolling update can deadlock host ports"
if grep -q 'type: Recreate' <<<"$traefik"; then
  fail "Recreate is not a DaemonSet strategy"
fi

SERVER="https://203.0.113.10:6443"
TOKEN="test-token"
CONTROL_PLANE=0
parse_args --server "$SERVER" --token "$TOKEN"
[[ "$CONTROL_PLANE" -eq 0 ]] || fail "worker parse set --control-plane"
parse_args --server "$SERVER" --token "$TOKEN" --control-plane --flannel-backend host-gw --tls-san dflow.example.com --tls-san apps.example.com
[[ "$CONTROL_PLANE" -eq 1 ]] || fail "control-plane flag was ignored"
[[ "$FLANNEL_BACKEND" == "host-gw" ]] || fail "flannel backend not recorded"
[[ "${TLS_SANS[0]}" == "dflow.example.com" && "${TLS_SANS[1]}" == "apps.example.com" ]] || fail "tls-san list mismatch"

if (parse_args --server "$SERVER" --token "$TOKEN" --control-plane); then
  fail "control-plane join without --flannel-backend should fail"
fi

join_cfg="$(control_plane_config_body)"
if grep -q 'cluster-init' <<<"$join_cfg"; then
  fail "joining server must not set cluster-init"
fi
grep -q '^server: "https://203.0.113.10:6443"$' <<<"$join_cfg" || fail "join URL missing"
grep -q "^token: 'test-token'$" <<<"$join_cfg" || fail "join token missing"
grep -q '^flannel-backend: host-gw$' <<<"$join_cfg" || fail "join flannel missing"
grep -q '^  - dflow.example.com$' <<<"$join_cfg" || fail "tls-san missing"
grep -q '^node-external-ip: ' <<<"$join_cfg" || fail "node-external-ip missing"

scripts/join-node.sh --help >/dev/null

helm template dflow packages/helm-chart --set global.domain=example.com >/tmp/dflow-ha-helm-ok.yaml
if helm template dflow packages/helm-chart --set global.domain=example.com --set server.replicaCount=2 >/tmp/dflow-ha-helm-bad.yaml 2>/tmp/dflow-ha-helm-bad.err; then
  fail "chart accepted server.replicaCount=2"
fi
grep -q 'server.replicaCount must stay 1' /tmp/dflow-ha-helm-bad.err || fail "replicaCount failure did not name the reason"
if helm template dflow packages/helm-chart --set global.domain=example.com --set server.autoscaling.enabled=true >/tmp/dflow-ha-helm-hpa.yaml 2>/tmp/dflow-ha-helm-hpa.err; then
  fail "chart accepted server.autoscaling.enabled"
fi

echo "ha-config-test: ok"
