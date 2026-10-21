#!/usr/bin/env bash
# Join this Ubuntu machine to an existing dFlow k3s cluster.
# See docs/INSTALL.md.
#
#   sudo ./scripts/join-node.sh --server https://203.0.113.10:6443 --token '<token>'
#   sudo ./scripts/join-node.sh --server https://203.0.113.10:6443 --token '<token>' \
#     --control-plane --flannel-backend vxlan --tls-san dflow.example.com
#
# The server URL and token are printed by scripts/install.sh on the first server.
# The token is also in /var/lib/rancher/k3s/server/node-token.
# --server is that API URL. --control-plane joins embedded etcd as another
# server. Without it, this host joins as a worker.
set -euo pipefail

SCRIPT_NAME=join-node.sh
SERVER=""
TOKEN=""
K3S_BIN_VERSION=""
CONTROL_PLANE=0
FLANNEL_BACKEND=""
NODE_IP=""
NODE_EXTERNAL_IP=""
TLS_SANS=()

die() {
  echo "${SCRIPT_NAME}: $*" >&2
  exit 1
}

log() {
  echo "== $*"
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/join-node.sh --server https://<server-ip>:6443 --token <token>
  sudo ./scripts/join-node.sh --server https://<server-ip>:6443 --token <token> \
    --control-plane --flannel-backend vxlan|host-gw [--tls-san HOST]

  --server URL              Kubernetes API of an existing server, https://<ip>:6443
  --token TOKEN             token printed by scripts/install.sh on the first server
  --control-plane           join as another k3s server (embedded etcd), not a worker
  --flannel-backend NAME    vxlan or host-gw; required with --control-plane
  --tls-san HOST            extra name on this server's API certificate (repeatable)
  --node-external-ip ADDR   advertised node IP; default is this host's default-route address
  --k3s-version V           optional k3s version passed to the installer

Without --control-plane the host joins as a worker. With --control-plane it
joins the embedded etcd quorum. The first server must already have been
started with cluster-init. Add servers until there are three. Two servers do
not provide high availability.

Run this on a fresh Ubuntu 22.04 or 24.04 machine. Running it again with the
same server and token leaves a healthy node in place.

On an existing server, `sudo kubectl get nodes` lists this host as Ready.
A worker's ROLES column is empty. A control-plane join shows control-plane,etcd.

Servers must accept TCP 6443, TCP 2379, and TCP 2380 from each other. All
nodes need TCP 10250, and UDP 8472 when flannel uses vxlan. See docs/INSTALL.md.
EOF
}

parse_args() {
  CONTROL_PLANE=0
  FLANNEL_BACKEND=""
  TLS_SANS=()
  NODE_EXTERNAL_IP=""
  K3S_BIN_VERSION=""
  SERVER=""
  TOKEN=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)
        [[ $# -ge 2 ]] || die "--server needs https://<server-ip>:6443"
        SERVER="$2"
        shift 2
        ;;
      --server=*)
        SERVER="${1#--server=}"
        shift
        ;;
      --token)
        [[ $# -ge 2 ]] || die "--token needs the token from the first server"
        TOKEN="$2"
        shift 2
        ;;
      --token=*)
        TOKEN="${1#--token=}"
        shift
        ;;
      --control-plane)
        CONTROL_PLANE=1
        shift
        ;;
      --flannel-backend)
        [[ $# -ge 2 ]] || die "--flannel-backend needs vxlan or host-gw"
        FLANNEL_BACKEND="$2"
        shift 2
        ;;
      --flannel-backend=*)
        FLANNEL_BACKEND="${1#--flannel-backend=}"
        shift
        ;;
      --tls-san)
        [[ $# -ge 2 ]] || die "--tls-san needs a hostname or IP"
        TLS_SANS+=("$2")
        shift 2
        ;;
      --tls-san=*)
        TLS_SANS+=("${1#--tls-san=}")
        shift
        ;;
      --node-external-ip)
        [[ $# -ge 2 ]] || die "--node-external-ip needs an IPv4 address"
        NODE_EXTERNAL_IP="$2"
        shift 2
        ;;
      --node-external-ip=*)
        NODE_EXTERNAL_IP="${1#--node-external-ip=}"
        shift
        ;;
      --k3s-version)
        [[ $# -ge 2 ]] || die "--k3s-version needs a value such as v1.33.5+k3s1"
        K3S_BIN_VERSION="$2"
        shift 2
        ;;
      --k3s-version=*)
        K3S_BIN_VERSION="${1#--k3s-version=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1 (see --help)"
        ;;
    esac
  done
  [[ -n "$SERVER" ]] || die "--server is required, for example https://203.0.113.10:6443"
  [[ -n "$TOKEN" ]] || die "--token is required. On the first server, read it with: sudo cat /var/lib/rancher/k3s/server/node-token"
  if [[ "$CONTROL_PLANE" -eq 1 ]]; then
    case "$FLANNEL_BACKEND" in
      vxlan|host-gw) ;;
      "")
        die "--flannel-backend is required with --control-plane. On the first server, read flannel-backend from /etc/rancher/k3s/config.yaml."
        ;;
      *)
        die "--flannel-backend must be vxlan or host-gw (got ${FLANNEL_BACKEND})"
        ;;
    esac
  fi
}

validate_server() {
  [[ "$SERVER" == https://* ]] || die "server must start with https://, for example https://203.0.113.10:6443 (got ${SERVER})"
  local rest="${SERVER#https://}"
  [[ "$rest" != */* && "$rest" != *" "* ]] || die "server URL must be https://<server-ip>:6443 with no path (got ${SERVER})"
  [[ "$rest" == *:* ]] || die "server URL must include port 6443: https://<server-ip>:6443"
  local port="${rest##*:}"
  local host="${rest%:*}"
  [[ "$port" == "6443" ]] || die "server URL port must be 6443 (got ${port})"
  [[ -n "$host" && "$host" != *:* ]] || die "server host must be an IP or DNS name (got ${host})"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root: sudo ./scripts/join-node.sh --server ${SERVER} --token <token>"
}

require_ubuntu() {
  [[ -f /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "this script supports Ubuntu 22.04 and 24.04 (found ${ID:-unknown})"
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) die "this script supports Ubuntu 22.04 and 24.04 (found ${VERSION_ID:-unknown})" ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
}

detect_node_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    NODE_IP="$ip"
    return 0
  fi
  return 1
}

reject_wrong_role() {
  if [[ "$CONTROL_PLANE" -eq 1 ]]; then
    if systemctl cat k3s-agent.service >/dev/null 2>&1; then
      die "this machine is a k3s agent. Join a control-plane server from a fresh Ubuntu host."
    fi
    if [[ -f /etc/rancher/k3s/config.yaml ]] && grep -Eq '^cluster-init:[[:space:]]*true' /etc/rancher/k3s/config.yaml; then
      die "this machine initialized the etcd cluster. Run --control-plane on a different host."
    fi
    return 0
  fi
  if systemctl cat k3s.service >/dev/null 2>&1; then
    die "this machine already runs a k3s server. Run scripts/join-node.sh on a different Ubuntu host."
  fi
}

http_code() {
  local url="$1"
  shift
  local code
  code="$(curl -k -sS -o /tmp/dflow-join-body -w '%{http_code}' --connect-timeout 10 --max-time 20 "$@" "$url" || true)"
  if [[ -z "$code" ]]; then
    code="000"
  fi
  printf '%s' "$code"
}

check_server() {
  local code
  code="$(http_code "${SERVER}/ping")"
  if [[ "$code" == "000" ]]; then
    die "cannot reach ${SERVER}. An existing server must be running, and TCP 6443 must be open from this host. See docs/INSTALL.md for firewall ports."
  fi
  if [[ "$code" != "200" ]] || ! grep -q pong /tmp/dflow-join-body; then
    die "reached ${SERVER} but ${SERVER}/ping did not return pong (HTTP ${code}). Use https://<server-ip>:6443 from an existing server."
  fi
  code="$(http_code "${SERVER}/v1-k3s/config" -H "Authorization: Bearer ${TOKEN}")"
  case "$code" in
    200) ;;
    401|403)
      die "the join token was rejected by ${SERVER} (HTTP ${code}). On the first server, read a fresh token with: sudo cat /var/lib/rancher/k3s/server/node-token"
      ;;
    000)
      die "lost contact with ${SERVER} while checking the token. TCP 6443 must stay open from this host."
      ;;
    *)
      die "could not check the join token at ${SERVER}/v1-k3s/config (HTTP ${code})."
      ;;
  esac
}

strip_env_quotes() {
  local value="$1"
  if [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
    value="${value:1:$((${#value} - 2))}"
  fi
  printf '%s' "$value"
}

agent_env_matches() {
  local envfile="${K3S_AGENT_ENV_FILE:-/etc/systemd/system/k3s-agent.service.env}"
  [[ -f "$envfile" ]] || return 1
  local url="" token="" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="$(strip_env_quotes "${line#*=}")"
    case "$key" in
      K3S_URL) url="$value" ;;
      K3S_TOKEN) token="$value" ;;
    esac
  done < "$envfile"
  [[ "$url" == "$SERVER" && "$token" == "$TOKEN" ]]
}

quote_token() {
  local token_q="$TOKEN"
  token_q="${token_q//\'/\'\'}"
  printf '%s' "$token_q"
}

write_agent_config() {
  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/config.yaml <<EOF
server: "${SERVER}"
token: '$(quote_token)'
EOF
  chmod 600 /etc/rancher/k3s/config.yaml
}

control_plane_config_body() {
  detect_node_ip || die "could not find an IPv4 address on the default route"
  local external_ip="${NODE_EXTERNAL_IP:-$NODE_IP}"
  local san seen=" ${NODE_IP} "
  cat <<EOF
write-kubeconfig-mode: "644"
disable:
  - servicelb
server: "${SERVER}"
token: '$(quote_token)'
flannel-backend: ${FLANNEL_BACKEND}
node-external-ip: ${external_ip}
tls-san:
  - ${NODE_IP}
EOF
  if ((${#TLS_SANS[@]})); then
    for san in "${TLS_SANS[@]}"; do
      [[ "$san" != *" "* && "$san" != */* && -n "$san" ]] || die "--tls-san must be a hostname or IP (got ${san})"
      if [[ "$seen" == *" ${san} "* ]]; then
        continue
      fi
      seen+=" ${san} "
      printf '  - %s\n' "$san"
    done
  fi
}

write_control_plane_config() {
  mkdir -p /etc/rancher/k3s
  local rendered dest="/etc/rancher/k3s/config.yaml"
  rendered="$(control_plane_config_body)"
  if [[ -f "$dest" ]] && cmp -s - "$dest" <<<"${rendered}"; then
    return 0
  fi
  printf '%s\n' "$rendered" > "$dest"
  chmod 600 "$dest"
}

control_plane_config_matches() {
  local rendered dest="/etc/rancher/k3s/config.yaml"
  [[ -f "$dest" ]] || return 1
  rendered="$(control_plane_config_body)"
  cmp -s - "$dest" <<<"${rendered}"
}

dump_unit_log() {
  local unit="$1"
  echo "${SCRIPT_NAME}: recent ${unit} log:" >&2
  journalctl -u "$unit" -n 40 --no-pager >&2 || true
}

unit_auth_failed() {
  local unit="$1"
  journalctl -u "$unit" --since "5 min ago" --no-pager 2>/dev/null \
    | grep -Eiq '401 Unauthorized|failed to get CA certs|Node password rejected'
}

wait_for_unit() {
  local unit="$1"
  local attempt state
  for attempt in $(seq 1 36); do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    case "$state" in
      active)
        if unit_auth_failed "$unit"; then
          dump_unit_log "$unit"
          die "${unit} rejected the token. On the first server run: sudo cat /var/lib/rancher/k3s/server/node-token"
        fi
        return 0
        ;;
      failed)
        dump_unit_log "$unit"
        if unit_auth_failed "$unit"; then
          die "${unit} rejected the token. On the first server run: sudo cat /var/lib/rancher/k3s/server/node-token"
        fi
        die "${unit} failed to start."
        ;;
    esac
    sleep 5
  done
  dump_unit_log "$unit"
  die "${unit} did not become active. Check journalctl -u ${unit} on this host, and sudo kubectl get nodes on an existing server."
}

k3s_join_env() {
  K3S_JOIN_ENV=(
    "K3S_URL=${SERVER}"
    "K3S_TOKEN=${TOKEN}"
  )
  if [[ -n "$K3S_BIN_VERSION" ]]; then
    K3S_JOIN_ENV+=("INSTALL_K3S_VERSION=${K3S_BIN_VERSION}")
  fi
}

install_agent() {
  log "install k3s agent for ${SERVER}"
  write_agent_config
  k3s_join_env
  curl -sfL https://get.k3s.io | env "${K3S_JOIN_ENV[@]}" sh - \
    || die "k3s agent install failed. The download or the installer exited non-zero."
  systemctl enable k3s-agent >/dev/null 2>&1 || true
  wait_for_unit k3s-agent
}

install_control_plane() {
  log "install k3s server joined to ${SERVER}"
  write_control_plane_config
  k3s_join_env
  # K3S_URL alone makes the installer start an agent. INSTALL_K3S_EXEC=server
  # joins embedded etcd instead. Do not pass cluster-init here: that flag
  # creates a new etcd, it does not join one.
  K3S_JOIN_ENV+=("INSTALL_K3S_EXEC=server")
  curl -sfL https://get.k3s.io | env "${K3S_JOIN_ENV[@]}" sh - \
    || die "k3s server install failed. The download or the installer exited non-zero."
  systemctl enable k3s >/dev/null 2>&1 || true
  wait_for_unit k3s
}

finish_worker() {
  cat <<EOF

This host joined ${SERVER} as a worker.

On an existing server, wait until the node is Ready:

  sudo kubectl get nodes

Firewall ports between the nodes: TCP 6443 (this host to a server),
UDP 8472 (flannel VXLAN), and TCP 10250 (kubelet). docs/INSTALL.md has the
host-gw exception and the three-server etcd steps.
EOF
}

finish_control_plane() {
  cat <<EOF

This host joined ${SERVER} as a k3s server (embedded etcd).

On an existing server:

  sudo kubectl get nodes

This node should show control-plane,etcd and become Ready. Quorum needs an
odd count. Stop at three servers unless you are adding two more at once.
docs/INSTALL.md lists TCP 2379 and TCP 2380, which etcd needs between servers.
EOF
}

main() {
  parse_args "$@"
  validate_server
  require_root
  require_ubuntu
  reject_wrong_role
  check_server
  if [[ "$CONTROL_PLANE" -eq 1 ]]; then
    if control_plane_config_matches && systemctl is-active --quiet k3s; then
      log "k3s server is already joined to ${SERVER}"
    elif control_plane_config_matches; then
      log "restart k3s server for ${SERVER}"
      systemctl restart k3s \
        || die "k3s server restart failed."
      wait_for_unit k3s
    else
      install_control_plane
    fi
    finish_control_plane
    return 0
  fi
  if agent_env_matches && systemctl is-active --quiet k3s-agent; then
    log "k3s agent is already joined to ${SERVER}"
  elif agent_env_matches; then
    log "restart k3s agent for ${SERVER}"
    systemctl restart k3s-agent \
      || die "k3s agent restart failed."
    wait_for_unit k3s-agent
  else
    install_agent
  fi
  finish_worker
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
