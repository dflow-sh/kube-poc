#!/usr/bin/env bash
# Join this Ubuntu machine to an existing dFlow k3s server as a worker.
# See docs/INSTALL.md.
#
#   sudo ./scripts/join-node.sh --server https://203.0.113.10:6443 --token '<token>'
#
# The server URL and token are printed by scripts/install.sh on the first server.
# The token is also in /var/lib/rancher/k3s/server/node-token.
set -euo pipefail

SCRIPT_NAME=join-node.sh
SERVER=""
TOKEN=""
K3S_BIN_VERSION=""

die() {
  echo "${SCRIPT_NAME}: $*" >&2
  exit 1
}

log() {
  echo "== $*"
}

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/join-node.sh --server https://<first-server-ip>:6443 --token <token>

  --server URL     k3s API on the first server, https://<ip>:6443
  --token TOKEN    token printed by scripts/install.sh on the first server
  --k3s-version V  optional k3s version passed to the installer (default: current stable)

Run this on a fresh Ubuntu 22.04 or 24.04 machine. It installs the k3s agent
and joins this host as a worker. Running it again with the same server and
token does not reinstall a healthy agent.

On the first server, `sudo kubectl get nodes` lists this worker as Ready.

The first server must accept TCP 6443 from this host. Nodes also need UDP 8472
(flannel VXLAN) and TCP 10250 between them. See docs/INSTALL.md.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)
        [[ $# -ge 2 ]] || die "--server needs https://<first-server-ip>:6443"
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
}

validate_server() {
  [[ "$SERVER" == https://* ]] || die "server must start with https://, for example https://203.0.113.10:6443 (got ${SERVER})"
  local rest="${SERVER#https://}"
  [[ "$rest" != */* && "$rest" != *" "* ]] || die "server URL must be https://<first-server-ip>:6443 with no path (got ${SERVER})"
  [[ "$rest" == *:* ]] || die "server URL must include port 6443: https://<first-server-ip>:6443"
  local port="${rest##*:}"
  local host="${rest%:*}"
  [[ "$port" == "6443" ]] || die "server URL port must be 6443 (got ${port})"
  [[ -n "$host" && "$host" != *:* ]] || die "server host must be the first server IP or DNS name (got ${host})"
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

reject_existing_server() {
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
    die "cannot reach ${SERVER}. The first server must be running, and TCP 6443 must be open from this host. See docs/INSTALL.md for firewall ports."
  fi
  if [[ "$code" != "200" ]] || ! grep -q pong /tmp/dflow-join-body; then
    die "reached ${SERVER} but ${SERVER}/ping did not return pong (HTTP ${code}). Use https://<first-server-ip>:6443 from the first server."
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

write_agent_config() {
  mkdir -p /etc/rancher/k3s
  local token_q="$TOKEN"
  token_q="${token_q//\'/\'\'}"
  cat > /etc/rancher/k3s/config.yaml <<EOF
server: "${SERVER}"
token: '${token_q}'
EOF
  chmod 600 /etc/rancher/k3s/config.yaml
}

dump_agent_log() {
  echo "${SCRIPT_NAME}: recent k3s agent log:" >&2
  journalctl -u k3s-agent -n 40 --no-pager >&2 || true
}

agent_auth_failed() {
  journalctl -u k3s-agent --since "5 min ago" --no-pager 2>/dev/null \
    | grep -Eiq '401 Unauthorized|failed to get CA certs|Node password rejected'
}

wait_for_agent() {
  local attempt state
  for attempt in $(seq 1 36); do
    state="$(systemctl is-active k3s-agent 2>/dev/null || true)"
    case "$state" in
      active)
        if agent_auth_failed; then
          dump_agent_log
          die "k3s agent rejected the token. On the first server run: sudo cat /var/lib/rancher/k3s/server/node-token"
        fi
        return 0
        ;;
      failed)
        dump_agent_log
        if agent_auth_failed; then
          die "k3s agent rejected the token. On the first server run: sudo cat /var/lib/rancher/k3s/server/node-token"
        fi
        die "k3s agent failed to start."
        ;;
    esac
    sleep 5
  done
  dump_agent_log
  die "k3s agent did not become active. Check journalctl -u k3s-agent on this host, and sudo kubectl get nodes on the first server."
}

install_agent() {
  local -a envargs
  log "install k3s agent for ${SERVER}"
  write_agent_config
  envargs=(
    "K3S_URL=${SERVER}"
    "K3S_TOKEN=${TOKEN}"
  )
  if [[ -n "$K3S_BIN_VERSION" ]]; then
    envargs+=("INSTALL_K3S_VERSION=${K3S_BIN_VERSION}")
  fi
  curl -sfL https://get.k3s.io | env "${envargs[@]}" sh - \
    || die "k3s agent install failed. The download or the installer exited non-zero."
  systemctl enable k3s-agent >/dev/null 2>&1 || true
  wait_for_agent
}

main() {
  parse_args "$@"
  validate_server
  require_root
  require_ubuntu
  reject_existing_server
  check_server
  if agent_env_matches && systemctl is-active --quiet k3s-agent; then
    log "k3s agent is already joined to ${SERVER}"
  elif agent_env_matches; then
    log "restart k3s agent for ${SERVER}"
    systemctl restart k3s-agent \
      || die "k3s agent restart failed."
    wait_for_agent
  else
    install_agent
  fi
  cat <<EOF

This host joined ${SERVER} as a worker.

On the first server, wait until the node is Ready:

  sudo kubectl get nodes

Firewall ports between the nodes: TCP 6443 (workers to the first server),
UDP 8472 (flannel VXLAN), and TCP 10250 (kubelet). docs/INSTALL.md has the
host-gw exception and the later three-server etcd note.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
