#!/usr/bin/env bash
# Idempotent dFlow install for a fresh Ubuntu 22.04 or 24.04 server.
#
# Clone the public repository, then run this script from that checkout.
# See docs/INSTALL.md.
#
#   sudo ./scripts/install.sh
#   sudo ./scripts/install.sh --domain auto
#   sudo ./scripts/install.sh --api-domain paas.dflow.sh --apps-domain apps.dflow.sh --email ops@dflow.sh
#   sudo ./scripts/install.sh --domain auto --admin-password 'replace-this'
#
# The latest GitHub Release is used (CLI binary, ghcr.io server image, and
# Helm chart package). Release downloads are public and do not send a token.
# The server image is pulled from ghcr.io. If that pull fails, the script
# exits non-zero. It does not build this checkout unless --from-checkout is set.

set -euo pipefail

SCRIPT_NAME="${SCRIPT_NAME:-install.sh}"
RELEASE_REPO="${RELEASE_REPO:-dflow-sh/kube-poc}"

DFLOW_VERSION="${DFLOW_VERSION:-v0.0.0-dev}"
IMAGE="${IMAGE:-ghcr.io/dflow-sh/dflow-server:${DFLOW_VERSION}}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-password}"
DOMAIN="${DOMAIN:-auto}"
API_DOMAIN="${DFLOW_API_DOMAIN:-${API_DOMAIN:-}}"
APPS_DOMAIN="${DFLOW_APPS_DOMAIN:-${APPS_DOMAIN:-}}"
LE_EMAIL="${DFLOW_EMAIL:-${LETSENCRYPT_EMAIL:-${LE_EMAIL:-}}}"
TUNNEL_TOKEN="${DFLOW_TUNNEL_TOKEN:-${CLOUDFLARE_TUNNEL_TOKEN:-${TUNNEL_TOKEN:-}}}"
LE_STAGING="${DFLOW_LETSENCRYPT_STAGING:-0}"
SAMPLE_NAMESPACE="${SAMPLE_NAMESPACE:-dflow-install-check}"
SAMPLE_APP="${SAMPLE_APP:-dflow-install-check}"
SMOKE_SKIPPED=0
SAMPLE_IMAGE="${SAMPLE_IMAGE:-docker.io/traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44}"
SAMPLE_ENV="${SAMPLE_ENV:-WHOAMI_PORT_NUMBER=8080}"
GO_VERSION="${GO_VERSION:-1.26.0}"
HELM_VERSION="${HELM_VERSION:-v3.22.1}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
# stable channel on 2026-10-23. latest is v1.37.1+k3s1 and is not this pin.
INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.36.5+k3s1}"
STATE_DIR="${STATE_DIR:-/var/lib/dflow}"

ROOT=""
PUBLIC_IP=""
NODE_IP=""
API_HOST=""
APPS_BASE=""
TLS_ISSUER="dflow-ca"
USE_TUNNEL=0
CURL_INSECURE=1
HOSTNAME_OVERRIDE=""
APPS_DOMAIN_VALUE=""
DOMAIN_SET=0
API_DOMAIN_SET=0
APPS_DOMAIN_SET=0
EMAIL_SET=0
TUNNEL_SET=0
PASSWORD_SET=0
TRAEFIK_CONFIG_CHANGED=0
TRAEFIK_HOST_IP=""
GOARCH_NAME=""
CONFIG_CHANGED=0
NEED_K3S_INSTALL=0
FLANNEL_BACKEND=""
FROM_CHECKOUT=0
REQUESTED_VERSION=""

die() {
  trap - ERR
  echo "${SCRIPT_NAME}: $*" >&2
  exit 1
}

trap 'status=$?; echo "${SCRIPT_NAME}: command failed (exit ${status}) at line ${LINENO}" >&2' ERR

log() {
  echo "== $*"
}

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install.sh [options]

  --domain auto             use <public-ipv4>.sslip.io with a self-signed certificate
  --domain NAME             apps are <app>.NAME and the API is https://dflow.NAME
  --api-domain HOST         API hostname, for example paas.dflow.sh
  --apps-domain NAME        apps are <app>.NAME, for example hello.apps.dflow.sh
  --email ADDRESS           Let's Encrypt contact email (required for real domains)
  --letsencrypt-staging     use the Let's Encrypt staging issuer
  --tunnel-token TOKEN      Cloudflare Tunnel token when this host has no public IPv4
  --admin-password PASS     API password for user admin (default: password)
  --version TAG             install this release, for example v0.0.3
  --from-checkout           build the CLI and server image from this checkout

With no domain flags on a terminal, the script asks for the API host, the apps
domain, and an email. Press Enter to keep <public-ipv4>.sslip.io.

A second run with no domain flags, or with --domain auto again, keeps the
domains saved in /var/lib/dflow/install.env.

The server image is pulled from ghcr.io/dflow-sh/dflow-server. A pull that
fails is an error. The script does not reuse or build a checkout image unless
you pass --from-checkout. CLI binaries, checksums.txt, and the Helm chart are
downloaded from the public GitHub Release without a token.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "--domain needs a value (a DNS name, or auto)"
        DOMAIN="$2"
        DOMAIN_SET=1
        shift 2
        ;;
      --domain=*)
        DOMAIN="${1#--domain=}"
        DOMAIN_SET=1
        shift
        ;;
      --api-domain)
        [[ $# -ge 2 ]] || die "--api-domain needs a hostname such as paas.dflow.sh"
        API_DOMAIN="$2"
        API_DOMAIN_SET=1
        shift 2
        ;;
      --api-domain=*)
        API_DOMAIN="${1#--api-domain=}"
        API_DOMAIN_SET=1
        shift
        ;;
      --apps-domain)
        [[ $# -ge 2 ]] || die "--apps-domain needs a hostname such as apps.dflow.sh"
        APPS_DOMAIN="$2"
        APPS_DOMAIN_SET=1
        shift 2
        ;;
      --apps-domain=*)
        APPS_DOMAIN="${1#--apps-domain=}"
        APPS_DOMAIN_SET=1
        shift
        ;;
      --email)
        [[ $# -ge 2 ]] || die "--email needs an address"
        LE_EMAIL="$2"
        EMAIL_SET=1
        shift 2
        ;;
      --email=*)
        LE_EMAIL="${1#--email=}"
        EMAIL_SET=1
        shift
        ;;
      --letsencrypt-staging)
        LE_STAGING=1
        shift
        ;;
      --tunnel-token)
        [[ $# -ge 2 ]] || die "--tunnel-token needs a Cloudflare tunnel token"
        TUNNEL_TOKEN="$2"
        TUNNEL_SET=1
        shift 2
        ;;
      --tunnel-token=*)
        TUNNEL_TOKEN="${1#--tunnel-token=}"
        TUNNEL_SET=1
        shift
        ;;
      --admin-password)
        [[ $# -ge 2 ]] || die "--admin-password needs a value"
        ADMIN_PASSWORD="$2"
        PASSWORD_SET=1
        shift 2
        ;;
      --admin-password=*)
        ADMIN_PASSWORD="${1#--admin-password=}"
        PASSWORD_SET=1
        shift
        ;;
      --version)
        [[ $# -ge 2 ]] || die "--version needs a value such as v0.0.3"
        REQUESTED_VERSION="$2"
        shift 2
        ;;
      --version=*)
        REQUESTED_VERSION="${1#--version=}"
        shift
        ;;
      --from-checkout)
        FROM_CHECKOUT=1
        shift
        ;;
      -h|--help)
        usage
        trap - ERR
        exit 0
        ;;
      *)
        die "unknown argument: $1 (see --help)"
        ;;
    esac
  done
}

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root: sudo ./scripts/install.sh"
}

require_checkout() {
  local source="${BASH_SOURCE[0]}"
  [[ -n "$source" && -f "$source" ]] || die "run scripts/install.sh from a git checkout. A public raw URL is not the install path. See docs/INSTALL.md."
  ROOT="$(cd "$(dirname "$source")/.." && pwd)"
  [[ -f "$ROOT/packages/helm-chart/Chart.yaml" ]] || die "packages/helm-chart/Chart.yaml is missing. Clone dflow-sh/kube-poc and run sudo ./scripts/install.sh from that checkout."
  cert_manager_chart >/dev/null
  [[ -f "$ROOT/images/Dockerfile" ]] || die "images/Dockerfile is missing from this checkout"
}

cert_manager_chart() {
  local found="" extra
  for extra in "${ROOT}/packages/helm-chart/charts/"cert-manager-*.tgz; do
    [[ -f "$extra" ]] || die "the vendored cert-manager chart is missing from this checkout"
    [[ -z "$found" ]] || die "more than one vendored cert-manager chart is present"
    found="$extra"
  done
  [[ -n "$found" ]] || die "the vendored cert-manager chart is missing from this checkout"
  printf '%s' "$found"
}

require_ubuntu() {
  [[ -f /etc/os-release ]] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "this installer supports Ubuntu 22.04 and 24.04 (found ${ID:-unknown})"
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) die "this installer supports Ubuntu 22.04 and 24.04 (found ${VERSION_ID:-unknown})" ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) GOARCH_NAME="amd64" ;;
    aarch64|arm64) GOARCH_NAME="arm64" ;;
    *) die "unsupported architecture $(uname -m); use amd64 or arm64" ;;
  esac
}

is_public_ipv4() {
  local ip="$1" a b
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b _ _ <<<"$ip"
  a=$((10#$a))
  b=$((10#$b))
  if (( a == 0 || a == 10 || a == 127 || a >= 224 )); then
    return 1
  fi
  if (( a == 192 && b == 168 )); then
    return 1
  fi
  if (( a == 169 && b == 254 )); then
    return 1
  fi
  if (( a == 172 && b >= 16 && b <= 31 )); then
    return 1
  fi
  if (( a == 100 && b >= 64 && b <= 127 )); then
    return 1
  fi
  return 0
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

ip_is_local() {
  local ip="$1"
  [[ -n "$ip" ]] || return 1
  ip -4 -o addr show | awk '{ print $4 }' | cut -d/ -f1 | grep -Fxq "$ip"
}

detect_public_ip() {
  local ip="" candidate
  for candidate in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    ip="$(curl -4fsS --max-time 10 "$candidate" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_public_ipv4 "$ip"; then
      PUBLIC_IP="$ip"
      return 0
    fi
  done
  detect_node_ip || true
  if is_public_ipv4 "${NODE_IP:-}"; then
    PUBLIC_IP="$NODE_IP"
    log "public IP lookup failed; using the address on the default route (${PUBLIC_IP})"
    return 0
  fi
  return 1
}

valid_dns_name() {
  local name="$1"
  [[ -n "$name" && "$name" != *"/"* && "$name" != *" "* && "$name" != *":"* ]] || return 1
  [[ "$name" != "auto" ]] || return 1
  return 0
}

prompt_line() {
  local __var="$1" text="$2" value=""
  if [[ -t 0 ]]; then
    read -r -p "$text" value || true
  fi
  printf -v "$__var" '%s' "$value"
}

load_saved_endpoints() {
  local saved="${STATE_DIR}/install.env"
  [[ -f "$saved" ]] || return 1
  local keep_password="$ADMIN_PASSWORD"
  # shellcheck disable=SC1090
  source "$saved"
  if [[ "$PASSWORD_SET" -eq 1 ]]; then
    ADMIN_PASSWORD="$keep_password"
  fi
  [[ -n "${API_HOST:-}" && -n "${APPS_BASE:-}" ]] || return 1
  DOMAIN="$APPS_BASE"
  log "reusing saved endpoints from ${saved}"
  return 0
}

apply_tls_choice() {
  CURL_INSECURE=1
  if [[ "$APPS_BASE" == *.sslip.io || "$API_HOST" == *.sslip.io ]]; then
    if [[ "$LE_STAGING" == "1" ]]; then
      [[ -n "$LE_EMAIL" ]] || die "--email is required with --letsencrypt-staging"
      TLS_ISSUER="letsencrypt-staging"
    else
      TLS_ISSUER="dflow-ca"
    fi
  elif [[ "$LE_STAGING" == "1" ]]; then
    [[ -n "$LE_EMAIL" ]] || die "--email is required with --letsencrypt-staging"
    TLS_ISSUER="letsencrypt-staging"
  else
    [[ -n "$LE_EMAIL" ]] || die "--email is required so Let's Encrypt can issue certificates for ${API_HOST}"
    TLS_ISSUER="letsencrypt-production"
    CURL_INSECURE=0
  fi
  if [[ "$API_HOST" != "dflow.${APPS_BASE}" ]]; then
    HOSTNAME_OVERRIDE="$API_HOST"
    APPS_DOMAIN_VALUE="$APPS_BASE"
  else
    HOSTNAME_OVERRIDE=""
    APPS_DOMAIN_VALUE=""
  fi
}

resolve_domain() {
  detect_node_ip || true
  detect_public_ip || true

  local domain_flags=0
  if [[ "$DOMAIN_SET" -eq 1 || "$API_DOMAIN_SET" -eq 1 || "$APPS_DOMAIN_SET" -eq 1 || "$TUNNEL_SET" -eq 1 ]]; then
    domain_flags=1
  fi
  # --domain auto picks sslip.io. A later run keeps the saved name so a
  # different answer from the public-IP lookup does not rebuild the cluster.
  local auto_only=0
  if [[ "$DOMAIN_SET" -eq 1 && "$DOMAIN" == "auto" && "$API_DOMAIN_SET" -eq 0 && "$APPS_DOMAIN_SET" -eq 0 && "$TUNNEL_SET" -eq 0 ]]; then
    auto_only=1
  fi
  if [[ "$domain_flags" -eq 0 || "$auto_only" -eq 1 ]] && load_saved_endpoints; then
    local saved_public="${PUBLIC_IP:-}"
    detect_node_ip || true
    # Keep the address from install.env. A new lookup can be a different
    # egress IP and would point --resolve at the wrong host.
    if [[ -z "$saved_public" ]]; then
      detect_public_ip || true
    else
      PUBLIC_IP="$saved_public"
    fi
    [[ -n "$TUNNEL_TOKEN" ]] && USE_TUNNEL=1
    apply_tls_choice
    log "API ${API_HOST}"
    log "apps *.${APPS_BASE}"
    return 0
  fi

  if [[ "$DOMAIN_SET" -eq 1 && -n "$DOMAIN" && "$DOMAIN" != "auto" && -z "$APPS_DOMAIN" ]]; then
    APPS_DOMAIN="$DOMAIN"
  fi

  if [[ "$domain_flags" -eq 0 && -t 0 && -z "$API_DOMAIN" && -z "$APPS_DOMAIN" && ( -z "$DOMAIN" || "$DOMAIN" == "auto" ) && -z "$TUNNEL_TOKEN" ]]; then
    echo "Press Enter on each line to use <public-ip>.sslip.io and a self-signed certificate."
    local entered_api="" entered_apps="" entered_email=""
    prompt_line entered_api "API host (example paas.dflow.sh): "
    prompt_line entered_apps "Apps domain (example apps.dflow.sh): "
    prompt_line entered_email "Let's Encrypt email: "
    [[ -n "$entered_api" ]] && API_DOMAIN="$entered_api"
    [[ -n "$entered_apps" ]] && APPS_DOMAIN="$entered_apps"
    [[ -n "$entered_email" ]] && LE_EMAIL="$entered_email"
  fi

  if [[ -z "$PUBLIC_IP" && -z "$TUNNEL_TOKEN" ]]; then
    if [[ -t 0 ]]; then
      local use_tunnel=""
      prompt_line use_tunnel "No public IPv4 detected. Use a Cloudflare Tunnel? [y/N]: "
      case "${use_tunnel}" in
        y|Y|yes|YES)
          prompt_line TUNNEL_TOKEN "Cloudflare tunnel token: "
          ;;
      esac
    fi
  fi
  if [[ -n "$TUNNEL_TOKEN" ]]; then
    USE_TUNNEL=1
  fi

  if [[ -z "$API_DOMAIN" && -z "$APPS_DOMAIN" ]]; then
    [[ -n "$PUBLIC_IP" ]] || die "no public IPv4 detected. Pass --api-domain, --apps-domain, and --tunnel-token, or run on a host with a public address."
    APPS_BASE="${PUBLIC_IP}.sslip.io"
    API_HOST="dflow.${APPS_BASE}"
    DOMAIN="$APPS_BASE"
  else
    [[ -n "$APPS_DOMAIN" ]] || die "--apps-domain is required with --api-domain"
    valid_dns_name "$APPS_DOMAIN" || die "apps domain must be a DNS name, not a URL: ${APPS_DOMAIN}"
    if [[ -z "$API_DOMAIN" ]]; then
      API_DOMAIN="dflow.${APPS_DOMAIN}"
    fi
    valid_dns_name "$API_DOMAIN" || die "API domain must be a DNS name, not a URL: ${API_DOMAIN}"
    API_HOST="$API_DOMAIN"
    APPS_BASE="$APPS_DOMAIN"
    DOMAIN="$APPS_BASE"
    if [[ "$USE_TUNNEL" -eq 0 && -z "$PUBLIC_IP" ]]; then
      die "no public IPv4 detected. Pass --tunnel-token to publish ${API_HOST} through Cloudflare, or run on a host with a public address."
    fi
  fi

  apply_tls_choice
  log "API https://${API_HOST}"
  log "apps https://<app>.${APPS_BASE}"
  if [[ -n "$PUBLIC_IP" ]]; then
    log "public IPv4 ${PUBLIC_IP}"
  elif [[ "$USE_TUNNEL" -eq 1 ]]; then
    log "no public IPv4; Cloudflare Tunnel will publish the hostnames"
  fi
  [[ -n "${NODE_IP:-}" ]] || die "could not find an IPv4 address on the default route"
}

install_packages() {
  log "packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl ca-certificates git jq python3 docker.io openssl iproute2
  systemctl enable --now docker
  local attempt
  for attempt in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      break
    fi
    if [[ "$attempt" -eq 30 ]]; then
      die "docker did not start. Check 'systemctl status docker'."
    fi
    sleep 2
  done
  # Docker writes a legacy iptables FORWARD policy of DROP. Bridged pod
  # traffic is evaluated there and never reaches the nft rules k3s installs,
  # so pods cannot resolve cluster DNS. Accept forwarded packets.
  if command -v iptables-legacy >/dev/null 2>&1; then
    iptables-legacy -P FORWARD ACCEPT || true
  fi
  if command -v ip6tables-legacy >/dev/null 2>&1; then
    ip6tables-legacy -P FORWARD ACCEPT || true
  fi
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  log "helm ${HELM_VERSION}"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${GOARCH_NAME}.tar.gz" -o /tmp/helm.tgz \
    || die "could not download helm ${HELM_VERSION}"
  tar -C /tmp -xzf /tmp/helm.tgz
  install -m 0755 "/tmp/linux-${GOARCH_NAME}/helm" /usr/local/bin/helm
}

install_go() {
  if [[ -x /usr/local/go/bin/go ]] && /usr/local/go/bin/go version | grep -q "go${GO_VERSION}"; then
    return 0
  fi
  log "Go ${GO_VERSION}"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH_NAME}.tar.gz" -o /tmp/go.tgz \
    || die "could not download Go ${GO_VERSION}"
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
}

choose_flannel() {
  if [[ -f /etc/rancher/k3s/config.yaml ]]; then
    local existing
    existing="$(awk '/^flannel-backend:/ { print $2; exit }' /etc/rancher/k3s/config.yaml)"
    if [[ -n "$existing" ]]; then
      FLANNEL_BACKEND="$existing"
      return 0
    fi
  fi
  modprobe vxlan >/dev/null 2>&1 || true
  if ip link add dflow-vxlan-test type vxlan id 42 dstport 4789 >/dev/null 2>&1; then
    ip link del dflow-vxlan-test >/dev/null 2>&1 || true
    FLANNEL_BACKEND="vxlan"
  else
    FLANNEL_BACKEND="host-gw"
    log "this kernel cannot create a vxlan device; k3s will use flannel host-gw"
  fi
}

k3s_server_config_body() {
  # kube-proxy sends the kubernetes API service to node-external-ip. An
  # egress address that is not configured on this host (NAT) is not answered
  # here, so in-cluster clients time out. Use the public IP only when it is
  # local. The join URL can still print the public address.
  local external_ip="${NODE_IP}"
  if ip_is_local "${PUBLIC_IP:-}"; then
    external_ip="${PUBLIC_IP}"
  fi
  # cluster-init starts embedded etcd. On a server that was already running
  # SQLite, the next k3s restart migrates the datastore. Additional servers
  # must not set this; they join with scripts/join-node.sh --control-plane.
  cat <<EOF
write-kubeconfig-mode: "644"
disable:
  - servicelb
flannel-backend: ${FLANNEL_BACKEND}
tls-san:
  - ${NODE_IP:-${PUBLIC_IP}}
  - ${API_HOST}
  - ${APPS_BASE}
node-external-ip: ${external_ip}
cluster-init: true
EOF
}

write_k3s_config() {
  choose_flannel
  mkdir -p /etc/rancher/k3s
  local rendered
  rendered="$(k3s_server_config_body)"
  if [[ ! -f /etc/rancher/k3s/config.yaml ]] || ! cmp -s - /etc/rancher/k3s/config.yaml <<<"${rendered}"; then
    printf '%s\n' "$rendered" > /etc/rancher/k3s/config.yaml
    CONFIG_CHANGED=1
  fi
}

traefik_helmchartconfig_body() {
  # ServiceLB (svclb-traefik) binds host ports through the CNI portmap plugin
  # and can stay stuck when that plugin cannot program the host. Traefik
  # itself joins the host network and listens on 80 and 443, so the service
  # stays ClusterIP and ServiceLB is not used.
  # A DaemonSet puts one pod on every node, which is what multiple A records
  # or a load balancer need. Chart 40 reads deployment.kind and the top-level
  # updateStrategy. RollingUpdate with maxUnavailable 1 drops the old pod on
  # a node before the new one binds host ports 80 and 443. Recreate is not a
  # DaemonSet strategy. HTTP is not redirected to HTTPS so cert-manager
  # HTTP-01 can use port 80.
  cat <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    hostNetwork: true
    deployment:
      kind: DaemonSet
      dnsPolicy: ClusterFirstWithHostNet
    updateStrategy:
      type: RollingUpdate
      rollingUpdate:
        maxUnavailable: 1
        maxSurge: 0
    service:
      spec:
        type: ClusterIP
    ports:
      web:
        port: 80
        exposedPort: 80
        protocol: TCP
      websecure:
        port: 443
        exposedPort: 443
        protocol: TCP
    securityContext:
      allowPrivilegeEscalation: true
      readOnlyRootFilesystem: true
      capabilities:
        drop: []
        add:
          - NET_BIND_SERVICE
    podSecurityContext:
      runAsNonRoot: false
      runAsUser: 0
      runAsGroup: 0
EOF
}

write_traefik_config() {
  mkdir -p /var/lib/rancher/k3s/server/manifests
  local dest="/var/lib/rancher/k3s/server/manifests/dflow-traefik-config.yaml"
  local tmp rendered
  rendered="$(traefik_helmchartconfig_body)"
  tmp="$(mktemp)"
  printf '%s\n' "$rendered" > "$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    TRAEFIK_CONFIG_CHANGED=0
    return 0
  fi
  mv "$tmp" "$dest"
  TRAEFIK_CONFIG_CHANGED=1
}

install_k3s() {
  write_k3s_config
  write_traefik_config
  if ! command -v k3s >/dev/null 2>&1 || ! systemctl cat k3s.service >/dev/null 2>&1; then
    NEED_K3S_INSTALL=1
  fi
  if [[ "$NEED_K3S_INSTALL" -eq 1 ]]; then
    log "install k3s ${INSTALL_K3S_VERSION}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION}" sh - \
      || die "k3s install failed"
  elif [[ "$CONFIG_CHANGED" -eq 1 ]]; then
    log "restart k3s to apply server config"
    systemctl restart k3s
  else
    log "k3s is already installed"
    systemctl start k3s
  fi
  export KUBECONFIG="$KUBECONFIG_PATH"
  local attempt
  for attempt in $(seq 1 60); do
    if kubectl get nodes >/dev/null 2>&1; then
      break
    fi
    if [[ "$attempt" -eq 60 ]]; then
      die "k3s API did not become reachable. Check 'systemctl status k3s' and 'journalctl -u k3s'."
    fi
    sleep 5
  done
  # kubectl get nodes exits 0 while the list is still empty. kubectl wait
  # --all then returns immediately with "no matching resources found" and
  # the script would stop before any workload exists. Wait until a node
  # object is present, then wait for Ready, and only then wait on workloads.
  wait_for_ready_node
}

wait_for_ready_node() {
  local attempt count wait_out
  log "waiting for a Ready node"
  for attempt in $(seq 1 120); do
    count="$(kubectl get nodes --no-headers 2>/dev/null | awk 'NF { n++ } END { print n+0 }' || true)"
    if [[ "${count:-0}" -ge 1 ]]; then
      if wait_out="$(kubectl wait --for=condition=Ready node --all --timeout=10m 2>&1)"; then
        [[ -n "$wait_out" ]] && printf '%s\n' "$wait_out"
        return 0
      fi
      if grep -q 'no matching resources found' <<<"$wait_out"; then
        log "node list is empty; waiting for a node to register before workload checks"
      else
        printf '%s\n' "$wait_out" >&2
        kubectl get nodes -o wide >&2 || true
        die "k3s node did not become Ready"
      fi
    elif [[ "$attempt" -eq 1 || $((attempt % 6)) -eq 0 ]]; then
      log "node list is empty; waiting for a node to register before workload checks"
    fi
    if [[ "$attempt" -eq 120 ]]; then
      kubectl get nodes -o wide >&2 || true
      die "timed out waiting for a Ready node. The node list stayed empty, so workloads were not waited on."
    fi
    sleep 5
  done
}

kubectl() {
  command kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
}

traefik_host_daemonset() {
  local kind host_net
  kind="$(kubectl -n kube-system get ds traefik -o jsonpath='{.kind}' 2>/dev/null || true)"
  host_net="$(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].spec.hostNetwork}' 2>/dev/null || true)"
  [[ "$kind" == "DaemonSet" && "$host_net" == "true" ]]
}

apply_traefik() {
  log "Traefik host network"
  local manifest="/var/lib/rancher/k3s/server/manifests/dflow-traefik-config.yaml"
  # k3s applies every file in this directory itself. apply is idempotent if
  # that controller created the HelmChartConfig first. create is not: it
  # returns AlreadyExists.
  local apply_out
  if ! apply_out="$(kubectl apply --server-side --force-conflicts --field-manager=dflow-install -f "$manifest" 2>&1)"; then
    if grep -q 'AlreadyExists' <<<"$apply_out" && kubectl -n kube-system get helmchartconfig traefik >/dev/null 2>&1; then
      log "traefik HelmChartConfig already exists; leaving the applied object"
    else
      printf '%s\n' "$apply_out" >&2
      die "could not apply ${manifest}"
    fi
  fi
  local attempt
  if [[ "$TRAEFIK_CONFIG_CHANGED" -eq 0 ]] && traefik_host_daemonset; then
    log "Traefik is already a host-network DaemonSet; not restarting it"
  else
    log "waiting for Traefik DaemonSet on the host network"
    for attempt in $(seq 1 60); do
      if kubectl -n kube-system get ds traefik >/dev/null 2>&1; then
        break
      fi
      if [[ "$attempt" -eq 60 ]]; then
        kubectl -n kube-system get deploy,ds,pods >&2 || true
        die "the traefik DaemonSet did not appear in kube-system"
      fi
      sleep 5
    done
    # The previous chart rendered a Deployment. It holds host ports 80 and
    # 443, so the DaemonSet pod cannot bind them until that Deployment is gone.
    # Helm deletes it once the chart no longer renders a Deployment; delete
    # here as well so a slow upgrade does not leave both objects running.
    if kubectl -n kube-system get deploy traefik >/dev/null 2>&1; then
      log "removing the Traefik Deployment so the DaemonSet can bind host ports"
      kubectl -n kube-system delete deploy traefik --wait=true --timeout=180s \
        || die "could not delete the Traefik Deployment"
    fi
  fi
  for attempt in $(seq 1 60); do
    if traefik_host_daemonset; then
      break
    fi
    if [[ "$attempt" -eq 60 ]]; then
      kubectl -n kube-system get ds,deploy,pods -l app.kubernetes.io/name=traefik >&2 || true
      die "traefik did not become a host-network DaemonSet"
    fi
    sleep 5
  done
  kubectl -n kube-system rollout status ds/traefik --timeout=10m \
    || die "traefik DaemonSet did not become ready"
  # Drop any ServiceLB DaemonSet left from an earlier LoadBalancer service.
  local ds
  while read -r ds; do
    [[ -n "$ds" ]] || continue
    kubectl -n kube-system delete "$ds" --ignore-not-found --wait=false
  done < <(kubectl -n kube-system get ds -o name | grep svclb-traefik || true)
}

verify_traefik() {
  log "verify Traefik is on the host IP"
  local host_net host_ip node_ips attempt
  host_net=""
  host_ip=""
  for attempt in $(seq 1 30); do
    host_net="$(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].spec.hostNetwork}' 2>/dev/null || true)"
    host_ip="$(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || true)"
    if [[ "$host_net" == "true" && -n "$host_ip" ]]; then
      break
    fi
    sleep 5
  done
  [[ "$host_net" == "true" ]] || die "traefik is not using the host network (hostNetwork=${host_net:-empty}). ServiceLB was not avoided."
  [[ -n "$host_ip" ]] || die "traefik has no hostIP"
  node_ips="$(kubectl get nodes -o jsonpath='{range .items[*].status.addresses[*]}{.address}{"\n"}{end}')"
  if ! grep -Fxq "$host_ip" <<<"$node_ips"; then
    echo "$node_ips" >&2
    die "traefik hostIP ${host_ip} is not one of this node's addresses"
  fi
  TRAEFIK_HOST_IP="$host_ip"
  local listen_ok=0
  for attempt in $(seq 1 30); do
    if ss -ltn | awk '{ print $4 }' | grep -Eq '(^|:)443$'; then
      listen_ok=1
      break
    fi
    sleep 2
  done
  [[ "$listen_ok" -eq 1 ]] || die "nothing is listening on TCP 443. Traefik did not bind the host."
  if kubectl -n kube-system get ds -o name | grep -q svclb-traefik; then
    kubectl -n kube-system get ds,svc,pods >&2 || true
    die "ServiceLB DaemonSet svclb-traefik is still present"
  fi
  log "Traefik hostIP ${TRAEFIK_HOST_IP} (public ${PUBLIC_IP}), listening on 443"
}

RELEASE_TAG=""
RELEASE_JSON=""
IMAGE_FROM_RELEASE=0
CHART_REF=""

release_token() {
  local token=""
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s' "$GITHUB_TOKEN"
    return 0
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s' "$GH_TOKEN"
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
  fi
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && command -v sudo >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    token="$(sudo -u "$SUDO_USER" -H gh auth token 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
  fi
  return 1
}

release_cache_dir() {
  local dir="${STATE_DIR:-/var/lib/dflow}"
  if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    printf '%s' "$dir"
    return 0
  fi
  dir="${TMPDIR:-/tmp}/dflow-release"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

ghcr_user() {
  local login=""
  if [[ -n "${GHCR_USER:-}" ]]; then
    printf '%s' "$GHCR_USER"
    return 0
  fi
  if [[ -n "${GITHUB_ACTOR:-}" ]]; then
    printf '%s' "$GITHUB_ACTOR"
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    login="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  if [[ -z "$login" && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && command -v sudo >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    login="$(sudo -u "$SUDO_USER" -H gh api user --jq .login 2>/dev/null || true)"
  fi
  if [[ -n "$login" ]]; then
    printf '%s' "$login"
    return 0
  fi
  printf '%s' "github"
}

checkout_image_tag() {
  local sha=""
  sha="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || true)"
  if [[ -n "$sha" ]]; then
    printf 'dev-%s' "$sha"
    return 0
  fi
  printf '%s' "${DFLOW_VERSION}"
}

load_release_json() {
  local requested="${1:-latest}" url dest
  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 is not installed, so release metadata cannot be read"
    return 1
  fi
  dest="$(release_cache_dir)/release.json"
  if [[ -n "$requested" && "$requested" != "latest" ]]; then
    url="https://api.github.com/repos/${RELEASE_REPO}/releases/tags/${requested}"
  else
    url="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
  fi
  # Public release metadata. Do not send a token: an invalid token makes
  # GitHub reject a release that anonymous clients can read.
  if ! curl -fsSL --retry 3 --retry-delay 2 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: dflow" \
    -o "$dest" "$url"; then
    log "GitHub release ${requested} for ${RELEASE_REPO} was not downloaded"
    return 1
  fi
  RELEASE_JSON="$dest"
  if ! RELEASE_TAG="$(python3 - "$dest" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("tag_name", ""))
PY
)"; then
    RELEASE_JSON=""
    log "GitHub release ${requested} did not return JSON"
    return 1
  fi
  if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_JSON=""
    return 1
  fi
  log "GitHub release ${RELEASE_TAG}"
}

download_release_asset() {
  local name="$1" dest="$2" url
  [[ -n "$RELEASE_TAG" ]] || return 1
  url="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}/${name}"
  log "downloading ${url}"
  curl -fL --retry 3 --retry-delay 2 \
    -H "User-Agent: dflow" \
    -o "$dest" "$url"
}

download_release_glob() {
  local regex="$1" dest="$2" name
  [[ -n "$RELEASE_JSON" ]] || return 1
  name="$(python3 - "$regex" "$RELEASE_JSON" <<'PY'
import json, re, sys
rx = re.compile(sys.argv[1])
data = json.load(open(sys.argv[2]))
for asset in data.get("assets") or []:
    asset_name = asset.get("name") or ""
    if rx.match(asset_name):
        print(asset_name)
        raise SystemExit(0)
raise SystemExit(1)
PY
)" || return 1
  download_release_asset "$name" "$dest"
}

verify_checksum() {
  local file="$1" asset="$2" required="${3:-}" sums dir base hash
  sums="$(mktemp)"
  if ! download_release_asset checksums.txt "$sums"; then
    rm -f "$sums"
    if [[ "$required" == "required" ]]; then
      log "release ${RELEASE_TAG} has no checksums.txt; refusing to install ${asset}"
      return 1
    fi
    log "release ${RELEASE_TAG} has no checksums.txt; not verifying ${asset}"
    return 0
  fi
  if ! grep -q -F "$asset" "$sums"; then
    rm -f "$sums"
    if [[ "$required" == "required" ]]; then
      log "checksums.txt has no line for ${asset}; refusing to install it"
      return 1
    fi
    log "checksums.txt has no line for ${asset}; not verifying it"
    return 0
  fi
  hash="$(grep -F "$asset" "$sums" | head -n 1 | awk '{ print $1 }')"
  dir="$(cd "$(dirname "$file")" && pwd)"
  base="$(basename "$file")"
  rm -f "$sums"
  local check_out
  if command -v sha256sum >/dev/null 2>&1; then
    check_out="$(printf '%s  %s\n' "$hash" "$base" | (cd "$dir" && sha256sum -c -) 2>&1)" || {
      log "checksum failed for ${asset}: ${check_out}"
      return 1
    }
  else
    check_out="$(printf '%s  %s\n' "$hash" "$base" | (cd "$dir" && shasum -a 256 -c -) 2>&1)" || {
      log "checksum failed for ${asset}: ${check_out}"
      return 1
    }
  fi
  log "checksum matched for ${asset}"
}

host_goos() {
  case "$(uname -s)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    *) die "unsupported operating system $(uname -s)" ;;
  esac
}

build_cli_binary() {
  install_go
  log "build dflow CLI from ${ROOT}"
  mkdir -p "${ROOT}/apps/cli/dist"
  (
    cd "$ROOT"
    CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_NAME" /usr/local/go/bin/go build -o apps/cli/dist/dflow ./apps/cli
  ) || die "go build of the dflow CLI failed"
}

build_host_cli() {
  local dest="$1" gobin="go"
  [[ -f "${ROOT}/apps/cli/main.go" ]] || return 1
  if [[ -x /usr/local/go/bin/go ]]; then
    gobin=/usr/local/go/bin/go
  fi
  if ! command -v "$gobin" >/dev/null 2>&1; then
    if [[ "$(host_goos)" == "linux" ]]; then
      install_go
      gobin=/usr/local/go/bin/go
    else
      log "Go ${GO_VERSION} is not on PATH"
      return 1
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  (
    cd "$ROOT"
    CGO_ENABLED=0 GOOS="$(host_goos)" GOARCH="$GOARCH_NAME" "$gobin" build -o "$dest" ./apps/cli
  )
}

place_cli() {
  local src="$1" dest="/usr/local/bin/dflow"
  if [[ -w /usr/local/bin ]]; then
    install -m 0755 "$src" "$dest"
  else
    sudo install -m 0755 "$src" "$dest"
  fi
  "$dest" version || die "the dflow binary at ${dest} does not run"
}

ghcr_pull_token() {
  if [[ -n "${GHCR_TOKEN:-}" ]]; then
    printf '%s' "$GHCR_TOKEN"
    return 0
  fi
  release_token
}

pull_log_is_auth() {
  local pull_log="$1"
  grep -Eqi '401|403|denied|unauthorized|insufficient_scope|authentication required' "$pull_log"
}

docker_pull_to_log() {
  local image="$1" pull_log="$2"
  docker pull "$image" >"$pull_log" 2>&1
}

import_pulled_release_image() {
  local image="$1" pull_log="$2"
  rm -f "$pull_log"
  docker save "$image" | k3s ctr images import - \
    || die "docker pulled ${image}, but k3s could not import it"
  IMAGE="$image"
  IMAGE_FROM_RELEASE=1
}

pull_release_image() {
  local image pull_log token user
  image="ghcr.io/dflow-sh/dflow-server:${RELEASE_TAG}"
  pull_log="$(mktemp)"
  # Pull before any registry login. A token without package read makes
  # ghcr.io deny a public image that an anonymous pull accepts.
  if docker_pull_to_log "$image" "$pull_log"; then
    import_pulled_release_image "$image" "$pull_log"
    return 0
  fi
  if pull_log_is_auth "$pull_log"; then
    docker logout ghcr.io >/dev/null 2>&1 || true
    if docker_pull_to_log "$image" "$pull_log"; then
      import_pulled_release_image "$image" "$pull_log"
      return 0
    fi
    token="$(ghcr_pull_token || true)"
    if [[ -n "$token" ]]; then
      user="$(ghcr_user)"
      local login_log
      login_log="$(mktemp)"
      if echo "$token" | docker login ghcr.io -u "$user" --password-stdin >"$login_log" 2>&1 \
        && docker_pull_to_log "$image" "$pull_log"; then
        rm -f "$login_log"
        import_pulled_release_image "$image" "$pull_log"
        return 0
      fi
      rm -f "$login_log"
      docker logout ghcr.io >/dev/null 2>&1 || true
    fi
  fi
  if pull_log_is_auth "$pull_log"; then
    log "pulling ${image} was denied"
  else
    log "could not pull ${image}"
  fi
  cat "$pull_log" >&2 || true
  rm -f "$pull_log"
  return 1
}

build_checkout_image() {
  if maybe_reuse_local_image; then
    return 0
  fi
  IMAGE="ghcr.io/dflow-sh/dflow-server:$(checkout_image_tag)"
  IMAGE_FROM_RELEASE=0
  log "building ${IMAGE} from ${ROOT}"
  build_cli_binary \
    || die "building the CLI from the checkout failed"
  docker build -f "${ROOT}/images/Dockerfile" -t "$IMAGE" "$ROOT" \
    || die "docker build of the checkout failed"
  docker save "$IMAGE" | k3s ctr images import - \
    || die "k3s could not import the checkout image"
}

import_or_build_image() {
  if [[ "$FROM_CHECKOUT" -eq 1 ]]; then
    log "server image will be built from this checkout (--from-checkout)"
    build_checkout_image
    return 0
  fi
  local requested="${RELEASE_TAG_REQUEST:-latest}"
  if [[ -z "$RELEASE_JSON" ]]; then
    load_release_json "$requested" \
      || die "GitHub release ${requested} for ${RELEASE_REPO} was not found. Refusing to build this checkout. Pass --from-checkout to build it."
  fi
  if ! pull_release_image; then
    die "could not pull ghcr.io/dflow-sh/dflow-server:${RELEASE_TAG}. Refusing to build or reuse a checkout image. Pass --from-checkout to build this checkout instead."
  fi
  log "imported ${IMAGE} from the GitHub release"
}

checkout_sha() {
  git -C "$ROOT" rev-parse HEAD 2>/dev/null || true
}

maybe_reuse_local_image() {
  local sha tag image
  sha="$(checkout_sha)"
  if [[ -z "${CHECKOUT_SHA:-}" && -f "${STATE_DIR}/install.env" ]]; then
    CHECKOUT_SHA="$( ( set +u; source "${STATE_DIR}/install.env"; printf '%s' "${CHECKOUT_SHA:-}" ) )"
  fi
  [[ -n "$sha" ]] || return 1
  tag="$(checkout_image_tag)"
  image="ghcr.io/dflow-sh/dflow-server:${tag}"
  if k3s ctr images ls 2>/dev/null | awk '{print $1}' | grep -Fxq "$image"; then
    IMAGE="$image"
    IMAGE_FROM_RELEASE=0
    log "reusing local image ${IMAGE}"
    return 0
  fi
  return 1
}

install_cli_release_or_build() {
  local goos asset dest sha
  sha="$(checkout_sha)"
  if [[ "$FROM_CHECKOUT" -eq 1 ]]; then
    if [[ -n "$sha" && "${CLI_FROM_CHECKOUT:-}" == "1" && "${CHECKOUT_SHA:-}" == "$sha" && -x /usr/local/bin/dflow ]] && /usr/local/bin/dflow version >/dev/null 2>&1; then
      log "CLI already installed for this checkout"
      return 0
    fi
    log "installing the checkout CLI (--from-checkout)"
    dest="/tmp/dflow-checkout"
    if ! build_host_cli "$dest"; then
      die "CLI install failed while building from the checkout."
    fi
    place_cli "$dest"
    CLI_FROM_CHECKOUT=1
    log "installed a CLI built from the checkout to /usr/local/bin/dflow"
    return 0
  fi
  goos="$(host_goos)"
  asset="dflow-${goos}-${GOARCH_NAME}"
  dest="/tmp/${asset}"
  if [[ -z "$RELEASE_JSON" ]]; then
    load_release_json "${RELEASE_TAG_REQUEST:-latest}" \
      || die "GitHub release ${RELEASE_TAG_REQUEST:-latest} for ${RELEASE_REPO} was not found. Refusing to build the checkout CLI. Pass --from-checkout to build it."
  fi
  if ! download_release_asset "$asset" "$dest"; then
    die "release asset ${asset} for ${RELEASE_TAG} could not be downloaded from ${RELEASE_REPO}. Refusing to build the checkout CLI. Pass --from-checkout to build it."
  fi
  chmod 0755 "$dest" || true
  if ! verify_checksum "$dest" "$asset" required; then
    die "release asset ${asset} failed its checksum. Refusing to install it or build the checkout CLI."
  fi
  if ! "$dest" version >/dev/null 2>&1; then
    die "release asset ${asset} was downloaded but did not run."
  fi
  place_cli "$dest"
  CLI_FROM_CHECKOUT=0
  log "installed ${asset} from release ${RELEASE_TAG} to /usr/local/bin/dflow"
}

install_cli() {
  install_cli_release_or_build
}

resolve_chart() {
  CHART_REF="${ROOT}/packages/helm-chart"
  if [[ "$IMAGE_FROM_RELEASE" -eq 1 && -n "$RELEASE_JSON" ]] && download_release_glob '^dflow-.+\.tgz$' /tmp/dflow-chart.tgz; then
    CHART_REF="/tmp/dflow-chart.tgz"
    log "using the Helm chart packaged in release ${RELEASE_TAG}"
    return 0
  fi
  if [[ "$IMAGE_FROM_RELEASE" -eq 0 ]]; then
    log "server image is from the checkout; using the checkout Helm chart"
  elif [[ -n "$RELEASE_JSON" ]]; then
    log "release ${RELEASE_TAG} has no Helm chart package; using the checkout chart"
  fi
  [[ -e "$CHART_REF" ]] || die "Helm chart install failed. No chart in the release and ${CHART_REF} is missing."
}

write_install_env() {
  mkdir -p "$STATE_DIR"
  local image_tag="${IMAGE##*:}"
  umask 077
  cat > "${STATE_DIR}/install.env" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
API_HOST=$(printf '%q' "$API_HOST")
APPS_BASE=$(printf '%q' "$APPS_BASE")
APPS_DOMAIN_VALUE=$(printf '%q' "$APPS_DOMAIN_VALUE")
HOSTNAME_OVERRIDE=$(printf '%q' "$HOSTNAME_OVERRIDE")
TLS_ISSUER=$(printf '%q' "$TLS_ISSUER")
LE_EMAIL=$(printf '%q' "$LE_EMAIL")
LE_STAGING=$(printf '%q' "$LE_STAGING")
USE_TUNNEL=$(printf '%q' "$USE_TUNNEL")
TUNNEL_TOKEN=$(printf '%q' "$TUNNEL_TOKEN")
CURL_INSECURE=$(printf '%q' "$CURL_INSECURE")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
ADMIN_USER=$(printf '%q' "$ADMIN_USER")
ADMIN_PASSWORD=$(printf '%q' "$ADMIN_PASSWORD")
IMAGE=$(printf '%q' "$IMAGE")
IMAGE_TAG=$(printf '%q' "$image_tag")
RELEASE_TAG=$(printf '%q' "${RELEASE_TAG:-}")
CHART_REF=$(printf '%q' "$CHART_REF")
CHECKOUT_SHA=$(printf '%q' "$(checkout_sha)")
CLI_FROM_CHECKOUT=$(printf '%q' "${CLI_FROM_CHECKOUT:-0}")
EOF
  chmod 600 "${STATE_DIR}/install.env"
}

apply_dflow_release() {
  resolve_chart
  mkdir -p "$STATE_DIR"
  local image_tag="${IMAGE##*:}"
  cat > "${STATE_DIR}/values.yaml" <<EOF
global:
  domain: $(yaml_quote "$DOMAIN")
  tlsIssuer: $(yaml_quote "$TLS_ISSUER")
  tlsIssuerEmail: $(yaml_quote "$LE_EMAIL")
$(if [[ -n "$APPS_DOMAIN_VALUE" ]]; then printf '  appsDomain: %s\n' "$(yaml_quote "$APPS_DOMAIN_VALUE")"; fi)
certManager:
  install: false
  enabled: true
dflowUI:
  enabled: false
api:
  adminPassword: $(yaml_quote "$ADMIN_PASSWORD")
ingress:
  ingressClassName: traefik
$(if [[ -n "$HOSTNAME_OVERRIDE" ]]; then printf '  hostnameOverride: %s\n' "$(yaml_quote "$HOSTNAME_OVERRIDE")"; fi)
server:
  defaultBuildMode: railpack
image:
  dflow:
    tag: $(yaml_quote "$image_tag")
EOF

  log "dFlow chart (${CHART_REF}, image tag ${image_tag})"
  helm upgrade --install dflow "$CHART_REF" \
    --namespace dflow --create-namespace \
    --values "${STATE_DIR}/values.yaml" \
    --timeout 15m \
    || die "helm install of the dFlow chart failed"
  write_install_env
  kubectl -n dflow rollout status deploy/dflow-server --timeout=15m \
    || die "dflow-server did not become ready. Check 'kubectl -n dflow describe deploy dflow-server'."
  if kubectl -n dflow get deploy dex >/dev/null 2>&1; then
    kubectl -n dflow rollout status deploy/dex --timeout=10m \
      || die "dex did not become ready"
  fi
  kubectl -n dflow wait --for=condition=Ready certificate/dflow --timeout=10m \
    || die "certificate/dflow did not become Ready"
}

install_charts() {
  log "cert-manager"
  helm upgrade --install cert-manager "$(cert_manager_chart)" \
    --namespace cert-manager --create-namespace \
    --values "${ROOT}/packages/helm-chart/cert-manager-images.yaml" \
    --set crds.enabled=true \
    --timeout 10m \
    || die "cert-manager install failed. Certificate CRDs have to exist before the dFlow chart."
  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=10m \
    || die "cert-manager did not become ready"
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10m \
    || die "cert-manager webhook did not become ready"
  apply_dflow_release
}

curl_code() {
  local url="$1"
  local resolve="${2:-}"
  local -a args=(-sS --max-time 20 -o /tmp/dflow-curl-body -w '%{http_code}')
  if [[ "${CURL_INSECURE:-1}" == "1" ]]; then
    args+=(-k)
  fi
  if [[ -n "$resolve" ]]; then
    args+=(--resolve "$resolve")
  fi
  local code
  code="$(curl "${args[@]}" "$url" || true)"
  if [[ -z "$code" ]]; then
    code="000"
  fi
  printf '%s' "$code"
}

curl_public_ok() {
  local url="$1"
  local host scheme port resolve code attempt note
  host="$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
  scheme="$(printf '%s' "$url" | sed -E 's#^([a-z]+)://.*#\1#')"
  if [[ "$scheme" == "https" ]]; then
    port=443
  else
    port=80
  fi
  for attempt in $(seq 1 36); do
    code="$(curl_code "$url")"
    if [[ "$code" == "200" ]]; then
      log "${url} returned 200"
      return 0
    fi
    note="$code via DNS"
    for resolve in \
      "${host}:${port}:${PUBLIC_IP:-}" \
      "${host}:${port}:${TRAEFIK_HOST_IP:-}"; do
      [[ -n "${resolve##*:}" ]] || continue
      code="$(curl_code "$url" "$resolve")"
      if [[ "$code" == "200" ]]; then
        log "${url} returned 200 via ${resolve}"
        return 0
      fi
      note="${note}, ${code} via ${resolve}"
    done
    if [[ "$attempt" -eq 36 ]]; then
      echo "${SCRIPT_NAME}: last response body for ${url}:" >&2
      cat /tmp/dflow-curl-body >&2 || true
      echo >&2
      echo "${SCRIPT_NAME}: status codes: ${note}" >&2
      return 1
    fi
    sleep 5
  done
  return 1
}

json_has_name() {
  local name="$1"
  python3 - "$name" <<'PY'
import json, sys
name = sys.argv[1]
raw = sys.stdin.read().strip()
if not raw or raw == "null":
    sys.exit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write(raw + "\n")
    sys.exit(2)
if data is None:
    sys.exit(1)
found = False
for item in data:
    if not isinstance(item, dict):
        continue
    meta = item.get("meta") if isinstance(item.get("meta"), dict) else item
    if isinstance(meta, dict) and meta.get("name") == name:
        found = True
        break
sys.exit(0 if found else 1)
PY
}

list_has_name() {
  local payload="$1" name="$2" status
  set +e
  printf '%s' "$payload" | json_has_name "$name"
  status=$?
  set -e
  if [[ "$status" -eq 2 ]]; then
    printf '%s\n' "$payload" >&2
    die "dflow did not return JSON"
  fi
  return "$status"
}

app_exists() {
  list_has_name "$1" "$SAMPLE_APP"
}

# True when some app already uses the smoke name, or an ingress already
# serves the smoke hostname. The caller must not delete that app.
smoke_in_use() {
  local host="${SAMPLE_APP}.${APPS_BASE}"
  local apps_json hosts
  apps_json="$(kubectl get apps.application.dflow.sh -A -o json 2>/dev/null || true)"
  if [[ -n "$apps_json" ]] && printf '%s' "$apps_json" | python3 -c '
import json, sys
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
for item in data.get("items") or []:
    if item.get("metadata", {}).get("name") == name:
        sys.exit(0)
sys.exit(1)
' "$SAMPLE_APP"; then
    return 0
  fi
  hosts="$(kubectl get ingress -A -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' 2>/dev/null || true)"
  if [[ -n "$hosts" ]] && grep -Fxq "$host" <<<"$hosts"; then
    return 0
  fi
  return 1
}

curl_health_ok() {
  local https_url="$1"
  local http_url="$2"
  local attempt
  for attempt in $(seq 1 24); do
    if curl_public_ok_once "$https_url" || curl_public_ok_once "$http_url"; then
      return 0
    fi
    sleep 5
  done
  echo "${SCRIPT_NAME}: last response body:" >&2
  cat /tmp/dflow-curl-body >&2 || true
  echo >&2
  return 1
}

curl_public_ok_once() {
  local url="$1"
  local host scheme port code
  host="$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
  scheme="$(printf '%s' "$url" | sed -E 's#^([a-z]+)://.*#\1#')"
  if [[ "$scheme" == "https" ]]; then
    port=443
  else
    port=80
  fi
  code="$(curl_code "$url")"
  if [[ "$code" == "200" ]]; then
    log "${url} returned 200"
    return 0
  fi
  local resolve
  for resolve in "${host}:${port}:${PUBLIC_IP}" "${host}:${port}:${TRAEFIK_HOST_IP}"; do
    [[ -n "${resolve##*:}" ]] || continue
    code="$(curl_code "$url" "$resolve")"
    if [[ "$code" == "200" ]]; then
      log "${url} returned 200 via ${resolve}"
      return 0
    fi
  done
  return 1
}

resolved_ipv4() {
  python3 - "$1" <<'PY'
import socket, sys
try:
    infos = socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)
except socket.gaierror:
    sys.exit(0)
if infos:
    print(infos[0][4][0])
PY
}

# sslip.io for an egress NAT address answers with an IP this host does not
# own. Pin the name to Traefik so login and curl reach the local port.
pin_host_to_traefik() {
  local host="$1" current
  [[ -n "$host" && -n "${TRAEFIK_HOST_IP:-}" ]] || return 0
  current="$(resolved_ipv4 "$host")"
  if [[ -n "$current" ]] && ip_is_local "$current"; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if [[ -f /etc/hosts ]]; then
    awk -v host="$host" '{
      skip = 0
      for (i = 2; i <= NF; i++) if ($i == host) skip = 1
      if (!skip) print
    }' /etc/hosts > "$tmp"
  fi
  printf '%s %s\n' "$TRAEFIK_HOST_IP" "$host" >> "$tmp"
  cat "$tmp" > /etc/hosts
  rm -f "$tmp"
  log "pinned ${host} to ${TRAEFIK_HOST_IP} (resolved ${current:-nowhere})"
}

self_test() {
  if [[ -z "${API_HOST:-}" ]]; then
    API_HOST="dflow.${DOMAIN}"
  fi
  if [[ -z "${APPS_BASE:-}" ]]; then
    APPS_BASE="$DOMAIN"
  fi
  if [[ -z "${TLS_ISSUER:-}" ]]; then
    TLS_ISSUER="dflow-ca"
    CURL_INSECURE=1
  fi
  if [[ -z "${PUBLIC_IP:-}" ]]; then
    detect_public_ip || true
  fi
  if [[ -z "${TRAEFIK_HOST_IP:-}" ]] && command -v kubectl >/dev/null 2>&1 && [[ -r "${KUBECONFIG_PATH:-}" ]]; then
    TRAEFIK_HOST_IP="$(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || true)"
  fi
  pin_host_to_traefik "$API_HOST"
  pin_host_to_traefik "${SAMPLE_APP}.${APPS_BASE}"
  log "API health"
  if ! curl_health_ok "https://${API_HOST}/ready" "http://${API_HOST}/ready"; then
    kubectl -n dflow get ingress,certificate,pods >&2 || true
    kubectl -n kube-system get svc,pods -l app.kubernetes.io/name=traefik >&2 || true
    die "API health check failed. https://${API_HOST}/ready and http://${API_HOST}/ready did not return 200."
  fi

  log "CLI self-test"
  log "API https://${API_HOST} user ${ADMIN_USER} password ${ADMIN_PASSWORD}"
  export PATH="/usr/local/bin:${PATH}"
  local -a login_args=(-u "$ADMIN_USER" -p "$ADMIN_PASSWORD")
  if [[ "${CURL_INSECURE:-1}" == "1" ]]; then
    login_args+=(--trust-ca)
  fi
  if ! dflow login "${login_args[@]}" "https://${API_HOST}" </dev/null; then
    die "dflow login to https://${API_HOST} failed. User ${ADMIN_USER}, password is the value printed below."
  fi

  if smoke_in_use; then
    SMOKE_SKIPPED=1
    log "smoke check skipped: ${SAMPLE_APP} or https://${SAMPLE_APP}.${APPS_BASE} is already in use"
    log "self-test passed: login, smoke check skipped, existing apps left in place"
    return 0
  fi

  local created_ns=0
  if ! dflow namespace show "$SAMPLE_NAMESPACE" >/dev/null 2>&1; then
    dflow namespace create "$SAMPLE_NAMESPACE" </dev/null \
      || die "could not create namespace ${SAMPLE_NAMESPACE}"
    created_ns=1
  fi
  dflow target "$SAMPLE_NAMESPACE" </dev/null \
    || die "could not target namespace ${SAMPLE_NAMESPACE}"

  log "push ${SAMPLE_IMAGE} as ${SAMPLE_APP} (${SAMPLE_ENV})"
  if ! printf '\n' | dflow push -n "$SAMPLE_APP" --container-image-url "$SAMPLE_IMAGE" -e "$SAMPLE_ENV"; then
    kubectl -n "$SAMPLE_NAMESPACE" get pods,ingress >&2 || true
    dflow app logs --staging "$SAMPLE_APP" >&2 || true
    die "dflow push of ${SAMPLE_APP} failed"
  fi

  if ! curl_public_ok "https://${SAMPLE_APP}.${APPS_BASE}/"; then
    kubectl -n "$SAMPLE_NAMESPACE" get pods,ingress >&2 || true
    die "https://${SAMPLE_APP}.${APPS_BASE}/ did not return HTTP 200"
  fi

  dflow app delete "$SAMPLE_APP" </dev/null \
    || die "dflow app delete ${SAMPLE_APP} failed"
  local attempt
  for attempt in $(seq 1 30); do
    app_list="$(dflow app list -o json)" || die "dflow app list failed after delete"
    if ! app_exists "$app_list"; then
      break
    fi
    if [[ "$attempt" -eq 30 ]]; then
      dflow app list >&2 || true
      die "app ${SAMPLE_APP} is still listed after delete"
    fi
    sleep 2
  done

  if [[ "$created_ns" -eq 1 ]]; then
    dflow namespace delete "$SAMPLE_NAMESPACE" -f </dev/null \
      || die "could not delete namespace ${SAMPLE_NAMESPACE}"
    if command -v kubectl >/dev/null 2>&1 && [[ -r "${KUBECONFIG_PATH:-}" ]]; then
      for attempt in $(seq 1 30); do
        if ! kubectl get ns "$SAMPLE_NAMESPACE" >/dev/null 2>&1; then
          break
        fi
        if [[ "$attempt" -eq 30 ]]; then
          kubectl get ns "$SAMPLE_NAMESPACE" -o yaml >&2 || true
          die "namespace ${SAMPLE_NAMESPACE} is still present after delete"
        fi
        sleep 2
      done
    fi
    local ns_list
    ns_list="$(dflow namespace list -o json)" || die "dflow namespace list failed after delete"
    if list_has_name "$ns_list" "$SAMPLE_NAMESPACE"; then
      die "namespace ${SAMPLE_NAMESPACE} is still listed after delete"
    fi
  fi
  log "self-test passed: login, push, HTTP 200, delete, and a clean namespace"
}

print_next() {
  local login_server login_mac api trust=""
  api="https://${API_HOST}"
  if [[ "${CURL_INSECURE:-1}" == "1" ]]; then
    trust="--trust-ca "
  fi
  login_server="$(printf 'dflow login -u %q -p %q %s%q' "$ADMIN_USER" "$ADMIN_PASSWORD" "$trust" "$api")"
  login_mac="$login_server"
  cat <<EOF

dFlow is installed.

  API:       ${api}
  User:      ${ADMIN_USER}
  Password:  ${ADMIN_PASSWORD}
  Apps:      https://<app>.${APPS_BASE}
  TLS:       ${TLS_ISSUER}

The installer already logged in. The smoke app is ${SAMPLE_APP} in namespace ${SAMPLE_NAMESPACE}.
When that name or https://${SAMPLE_APP}.${APPS_BASE} is already in use, the smoke push is skipped and the existing app is left in place.

On this server, repeat the check with docs/TESTING.md:

  export API_HOST=${API_HOST}
  export APPS_BASE=${APPS_BASE}
  ${login_server}

On a Mac, from a checkout of this repository:

  ./scripts/install-cli.sh --api ${api}
  ${login_mac}

Or download the public release asset dflow-darwin-arm64 or dflow-darwin-amd64 and check checksums.txt. A browser download may need: xattr -d com.apple.quarantine /usr/local/bin/dflow

Change the admin password before leaving the API on the public internet.
Helm values used for this install: ${STATE_DIR}/values.yaml
EOF
  print_join_info
}

print_join_info() {
  local token_file="/var/lib/rancher/k3s/server/node-token"
  local token server
  [[ -r "$token_file" ]] || die "k3s node token ${token_file} is missing, so a worker cannot join"
  token="$(tr -d '[:space:]' < "$token_file")"
  [[ -n "$token" ]] || die "k3s node token ${token_file} is empty"
  if [[ -z "${PUBLIC_IP:-}" ]]; then
    cat <<EOF

No public IPv4 was detected, so a join URL is not printed.
Workers and extra control-plane servers can join only if they can reach this node's Kubernetes API.
Use scripts/join-node.sh --control-plane for a second and third server once that address is known. docs/INSTALL.md describes the three-server layout.
EOF
    return 0
  fi
  server="https://${PUBLIC_IP}:6443"
  local flannel="${FLANNEL_BACKEND:-vxlan}"
  local tls_args=""
  if [[ -n "${API_HOST:-}" ]]; then
    tls_args="--tls-san ${API_HOST}"
  fi
  if [[ -n "${APPS_BASE:-}" && "${APPS_BASE}" != "${API_HOST:-}" ]]; then
    tls_args="${tls_args} --tls-san ${APPS_BASE}"
  fi
  cat <<EOF

This server starts embedded etcd (cluster-init). One server is not highly available.
Add two more servers before relying on failover. Do not stop at two: etcd then loses quorum when either server stops.

Join a worker from another Ubuntu 22.04 or 24.04 machine:

  sudo ./scripts/join-node.sh --server ${server} --token '${token}'

Join a second and a third control-plane server with the same token. docs/INSTALL.md has the firewall ports, including TCP 2379 and TCP 2380.

  sudo ./scripts/join-node.sh --server ${server} --token '${token}' --control-plane --flannel-backend ${flannel} ${tls_args}

The token is also in ${token_file}. The server URL uses this machine's public IPv4.
Point API and app DNS at every node that runs Traefik, or at a load balancer. A single sslip.io address reaches only one host.
EOF
}

name_resolves() {
  local host="$1" expect="${2:-}"
  python3 - "$host" "$expect" <<'PY'
import socket, sys
host, expect = sys.argv[1], sys.argv[2]
try:
    infos = socket.getaddrinfo(host, None, socket.AF_INET)
except socket.gaierror:
    sys.exit(1)
ips = {item[4][0] for item in infos}
if not ips:
    sys.exit(1)
if expect and expect not in ips:
    sys.exit(1)
sys.exit(0)
PY
}

print_dns_instructions() {
  if [[ "$USE_TUNNEL" -eq 1 ]]; then
    cat <<EOF

No public A records. In the Cloudflare tunnel, route these hostnames to http://localhost:80:

  ${API_HOST}
  *.${APPS_BASE}

The installer waits until both names resolve before it requests certificates.
EOF
    return 0
  fi
  if [[ "$APPS_BASE" == *.sslip.io ]]; then
    log "sslip.io publishes ${API_HOST} and *.${APPS_BASE} without DNS records"
    return 0
  fi
  cat <<EOF

Create these DNS records. The installer waits until they resolve before requesting certificates.

  A    ${API_HOST}        ${PUBLIC_IP}
  A    *.${APPS_BASE}     ${PUBLIC_IP}

EOF
}

wait_for_dns() {
  if [[ "$APPS_BASE" == *.sslip.io && "$USE_TUNNEL" -eq 0 ]]; then
    return 0
  fi
  local expect="" probe="dns-check.${APPS_BASE}"
  if [[ "$USE_TUNNEL" -eq 0 ]]; then
    expect="$PUBLIC_IP"
  fi
  log "waiting for DNS: ${API_HOST} and ${probe}"
  local attempt
  for attempt in $(seq 1 60); do
    if name_resolves "$API_HOST" "$expect" && name_resolves "$probe" "$expect"; then
      log "DNS is in place for ${API_HOST} and *.${APPS_BASE}"
      return 0
    fi
    if [[ "$attempt" -eq 60 ]]; then
      if [[ "$USE_TUNNEL" -eq 1 ]]; then
        die "timed out waiting for ${API_HOST} and ${probe} to resolve. Route them on the Cloudflare tunnel to http://localhost:80."
      fi
      die "timed out waiting for ${API_HOST} and ${probe} to resolve to ${PUBLIC_IP}"
    fi
    sleep 5
  done
}

install_cloudflared() {
  [[ "$USE_TUNNEL" -eq 1 ]] || return 0
  [[ -n "$TUNNEL_TOKEN" ]] || die "Cloudflare tunnel token is empty"
  if ! command -v cloudflared >/dev/null 2>&1; then
    log "install cloudflared"
    curl -fsSL -o /tmp/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${GOARCH_NAME}" \
      || die "could not download cloudflared"
    install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
  fi
  if systemctl is-active --quiet cloudflared; then
    log "cloudflared is already running"
    return 0
  fi
  cloudflared service uninstall >/dev/null 2>&1 || true
  cloudflared service install "$TUNNEL_TOKEN" \
    || die "cloudflared service install failed"
  systemctl enable --now cloudflared \
    || die "cloudflared did not start"
  systemctl is-active --quiet cloudflared \
    || die "cloudflared is not active. Check 'systemctl status cloudflared'."
  log "cloudflared is running"
}

main() {
  parse_args "$@"
  if [[ "$FROM_CHECKOUT" -eq 1 && -n "$REQUESTED_VERSION" ]]; then
    die "--from-checkout cannot be combined with --version"
  fi
  if [[ -n "$REQUESTED_VERSION" ]]; then
    RELEASE_TAG_REQUEST="$REQUESTED_VERSION"
  fi
  require_root
  require_checkout
  require_ubuntu
  detect_arch
  resolve_domain
  print_dns_instructions
  install_packages
  install_helm
  install_k3s
  apply_traefik
  verify_traefik
  install_cloudflared
  wait_for_dns
  import_or_build_image
  install_cli
  install_charts
  self_test
  print_next
  trap - ERR
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
