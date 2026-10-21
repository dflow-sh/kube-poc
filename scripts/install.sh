#!/usr/bin/env bash
# Idempotent dFlow install for a fresh Ubuntu 22.04 or 24.04 server.
#
# The repository is private. Clone it first (GitHub token or deploy key),
# then run this script from that checkout. See docs/INSTALL.md.
#
#   sudo ./scripts/install.sh
#   sudo ./scripts/install.sh --domain auto
#   sudo ./scripts/install.sh --domain apps.example.com
#   sudo ./scripts/install.sh --domain auto --admin-password 'replace-this'
#
# The latest GitHub Release is tried first (CLI binary, ghcr.io server image,
# and Helm chart package). The repository is private, so that download needs
# GITHUB_TOKEN, GH_TOKEN, or an authenticated gh session. If no release asset
# is available, the script builds from this checkout. If both fail, it exits
# non-zero.

set -euo pipefail

SCRIPT_NAME="${SCRIPT_NAME:-install.sh}"
RELEASE_REPO="${RELEASE_REPO:-dflow-sh/kube-poc}"

DFLOW_VERSION="${DFLOW_VERSION:-v1.14.3}"
IMAGE="${IMAGE:-ghcr.io/dflow-sh/dflow-server:${DFLOW_VERSION}}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-password}"
DOMAIN="${DOMAIN:-auto}"
SAMPLE_NAMESPACE="${SAMPLE_NAMESPACE:-sample}"
SAMPLE_APP="${SAMPLE_APP:-hello}"
SAMPLE_IMAGE="${SAMPLE_IMAGE:-traefik/whoami}"
GO_VERSION="${GO_VERSION:-1.26.0}"
HELM_VERSION="${HELM_VERSION:-v3.17.3}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
STATE_DIR="${STATE_DIR:-/var/lib/dflow}"

ROOT=""
PUBLIC_IP=""
TRAEFIK_HOST_IP=""
GOARCH_NAME=""
CONFIG_CHANGED=0
NEED_K3S_INSTALL=0
FLANNEL_BACKEND=""

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
Usage: sudo ./scripts/install.sh [--domain NAME|auto] [--admin-password PASSWORD]

  --domain auto          use <public-ipv4>.sslip.io (this is the default)
  --domain NAME          use NAME (wildcard DNS must point at this server)
  --admin-password PASS  API password for user admin (default: password)

Run this from a clone of dflow-sh/kube-poc. docs/INSTALL.md has the clone
command. docs/TESTING.md is the manual check after this script finishes.

GITHUB_TOKEN or GH_TOKEN (repo read) selects the latest GitHub Release.
sudo does not keep that variable unless you pass --preserve-env=GITHUB_TOKEN.
An existing gh login is also used, including the invoking user's login when
this script runs under sudo. Without a token, the checkout is built locally.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        [[ $# -ge 2 ]] || die "--domain needs a value (a DNS name, or auto)"
        DOMAIN="$2"
        shift 2
        ;;
      --domain=*)
        DOMAIN="${1#--domain=}"
        shift
        ;;
      --admin-password)
        [[ $# -ge 2 ]] || die "--admin-password needs a value"
        ADMIN_PASSWORD="$2"
        shift 2
        ;;
      --admin-password=*)
        ADMIN_PASSWORD="${1#--admin-password=}"
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
  [[ -f "$ROOT/packages/helm-chart/charts/cert-manager-v1.19.3.tgz" ]] || die "the vendored cert-manager chart is missing from this checkout"
  [[ -f "$ROOT/images/Dockerfile" ]] || die "images/Dockerfile is missing from this checkout"
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

detect_public_ip() {
  local ip="" candidate
  for candidate in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://icanhazip.com"; do
    ip="$(curl -4fsS --max-time 10 "$candidate" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      PUBLIC_IP="$ip"
      return 0
    fi
  done
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    PUBLIC_IP="$ip"
    log "public IP lookup failed; using the address on the default route (${PUBLIC_IP})"
    return 0
  fi
  return 1
}

resolve_domain() {
  detect_public_ip || true
  if [[ -z "$DOMAIN" || "$DOMAIN" == "auto" ]]; then
    [[ -n "$PUBLIC_IP" ]] || die "could not detect a public IPv4 address. Pass --domain your.dns.name"
    DOMAIN="${PUBLIC_IP}.sslip.io"
  fi
  [[ "$DOMAIN" != *"/"* && "$DOMAIN" != *" "* ]] || die "domain must be a DNS name, not a URL: ${DOMAIN}"
  if [[ -z "$PUBLIC_IP" ]]; then
    die "could not detect this server's IPv4 address. Set it with a reachable --domain and retry from a host that can reach the internet."
  fi
  log "domain ${DOMAIN}"
  log "public IPv4 ${PUBLIC_IP}"
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
      return 0
    fi
    sleep 2
  done
  die "docker did not start. Check 'systemctl status docker'."
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

write_k3s_config() {
  choose_flannel
  mkdir -p /etc/rancher/k3s
  local rendered
  rendered="$(cat <<EOF
write-kubeconfig-mode: "644"
disable:
  - servicelb
flannel-backend: ${FLANNEL_BACKEND}
tls-san:
  - ${PUBLIC_IP}
  - ${DOMAIN}
  - dflow.${DOMAIN}
node-external-ip: ${PUBLIC_IP}
EOF
)"
  if [[ ! -f /etc/rancher/k3s/config.yaml ]] || ! cmp -s - /etc/rancher/k3s/config.yaml <<<"${rendered}"; then
    printf '%s\n' "$rendered" > /etc/rancher/k3s/config.yaml
    CONFIG_CHANGED=1
  fi
}

write_traefik_config() {
  # ServiceLB (svclb-traefik) binds host ports through the CNI portmap plugin
  # and can stay stuck when that plugin cannot program the host. Traefik
  # itself joins the host network and listens on 80 and 443, so the service
  # stays ClusterIP and ServiceLB is not used.
  mkdir -p /var/lib/rancher/k3s/server/manifests
  cat > /var/lib/rancher/k3s/server/manifests/dflow-traefik-config.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    hostNetwork: true
    deployment:
      dnsPolicy: ClusterFirstWithHostNet
    service:
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

install_k3s() {
  write_k3s_config
  write_traefik_config
  if ! command -v k3s >/dev/null 2>&1 || ! systemctl cat k3s.service >/dev/null 2>&1; then
    NEED_K3S_INSTALL=1
  fi
  if [[ "$NEED_K3S_INSTALL" -eq 1 ]]; then
    log "install k3s"
    curl -sfL https://get.k3s.io | sh - \
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
  kubectl wait --for=condition=Ready node --all --timeout=10m \
    || die "k3s node did not become Ready"
}

kubectl() {
  command kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"
}

apply_traefik() {
  log "Traefik host network"
  kubectl apply -f /var/lib/rancher/k3s/server/manifests/dflow-traefik-config.yaml
  local attempt
  for attempt in $(seq 1 60); do
    if kubectl -n kube-system get deploy traefik >/dev/null 2>&1; then
      break
    fi
    if [[ "$attempt" -eq 60 ]]; then
      die "the traefik deployment did not appear in kube-system"
    fi
    sleep 5
  done
  kubectl -n kube-system rollout restart deploy/traefik
  kubectl -n kube-system rollout status deploy/traefik --timeout=10m \
    || die "traefik did not become ready after switching to the host network"
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
  local requested="${1:-latest}" token url dest
  if ! command -v python3 >/dev/null 2>&1; then
    log "python3 is not installed, so release metadata cannot be read"
    return 1
  fi
  token="$(release_token || true)"
  if [[ -z "$token" ]]; then
    log "no GITHUB_TOKEN, GH_TOKEN, or gh login is available"
    return 1
  fi
  dest="$(release_cache_dir)/release.json"
  if [[ -n "$requested" && "$requested" != "latest" ]]; then
    url="https://api.github.com/repos/${RELEASE_REPO}/releases/tags/${requested}"
  else
    url="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
  fi
  if ! curl -fsSL --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
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
  local name="$1" dest="$2" token url
  [[ -n "$RELEASE_JSON" ]] || return 1
  url="$(python3 - "$name" "$RELEASE_JSON" <<'PY'
import json, sys
name, path = sys.argv[1], sys.argv[2]
data = json.load(open(path))
for asset in data.get("assets") or []:
    if asset.get("name") == name:
        print(asset.get("url") or "")
        raise SystemExit(0)
raise SystemExit(1)
PY
)" || return 1
  [[ -n "$url" ]] || return 1
  token="$(release_token || true)"
  [[ -n "$token" ]] || return 1
  curl -fL --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/octet-stream" \
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
  local file="$1" asset="$2" sums dir base hash
  sums="$(mktemp)"
  if ! download_release_asset checksums.txt "$sums"; then
    log "release ${RELEASE_TAG} has no checksums.txt; not verifying ${asset}"
    rm -f "$sums"
    return 0
  fi
  if ! grep -q -F "$asset" "$sums"; then
    log "checksums.txt has no line for ${asset}; not verifying it"
    rm -f "$sums"
    return 0
  fi
  hash="$(grep -F "$asset" "$sums" | head -n 1 | awk '{ print $1 }')"
  dir="$(cd "$(dirname "$file")" && pwd)"
  base="$(basename "$file")"
  rm -f "$sums"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$hash" "$base" | (cd "$dir" && sha256sum -c -)
  else
    printf '%s  %s\n' "$hash" "$base" | (cd "$dir" && shasum -a 256 -c -)
  fi
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

pull_release_image() {
  local token image tar user
  image="ghcr.io/dflow-sh/dflow-server:${RELEASE_TAG}"
  token="$(release_token || true)"
  if [[ -n "$token" ]]; then
    user="$(ghcr_user)"
    echo "$token" | docker login ghcr.io -u "$user" --password-stdin >/dev/null \
      || log "could not log in to ghcr.io"
  fi
  if docker pull "$image"; then
    docker save "$image" | k3s ctr images import - \
      || die "docker pulled ${image}, but k3s could not import it"
    IMAGE="$image"
    IMAGE_FROM_RELEASE=1
    return 0
  fi
  tar="/tmp/dflow-server-linux-${GOARCH_NAME}.tar.gz"
  if download_release_asset "dflow-server-linux-${GOARCH_NAME}.tar.gz" "$tar"; then
    gunzip -c "$tar" | k3s ctr images import - \
      || die "the release image archive was downloaded, but k3s could not import it"
    IMAGE="$image"
    IMAGE_FROM_RELEASE=1
    return 0
  fi
  return 1
}

import_or_build_image() {
  local release_note="no GitHub release could be downloaded"
  if [[ -z "$RELEASE_JSON" ]]; then
    load_release_json "${RELEASE_TAG_REQUEST:-latest}" || true
  fi
  if [[ -n "$RELEASE_JSON" ]]; then
    release_note="release ${RELEASE_TAG} had no server image for linux/${GOARCH_NAME}"
    if pull_release_image; then
      log "imported ${IMAGE} from the GitHub release"
      return 0
    fi
    log "$release_note"
  else
    log "${release_note}. Set GITHUB_TOKEN or GH_TOKEN, or run gh auth login. Building from the checkout."
  fi
  IMAGE="ghcr.io/dflow-sh/dflow-server:$(checkout_image_tag)"
  IMAGE_FROM_RELEASE=0
  log "building ${IMAGE} from ${ROOT}"
  build_cli_binary \
    || die "server image install failed. ${release_note}. Building the CLI from the checkout also failed."
  docker build -f "${ROOT}/images/Dockerfile" -t "$IMAGE" "$ROOT" \
    || die "server image install failed. ${release_note}. docker build of the checkout also failed."
  docker save "$IMAGE" | k3s ctr images import - \
    || die "server image install failed. ${release_note}. Importing the locally built image into k3s also failed."
}

install_cli_release_or_build() {
  local goos asset dest
  goos="$(host_goos)"
  asset="dflow-${goos}-${GOARCH_NAME}"
  dest="/tmp/${asset}"
  if [[ -z "$RELEASE_JSON" ]]; then
    load_release_json "${RELEASE_TAG_REQUEST:-latest}" || true
  fi
  if [[ -n "$RELEASE_JSON" ]] && download_release_asset "$asset" "$dest"; then
    if verify_checksum "$dest" "$asset" && "$dest" version >/dev/null 2>&1; then
      place_cli "$dest"
      log "installed ${asset} from release ${RELEASE_TAG} to /usr/local/bin/dflow"
      return 0
    fi
    log "release asset ${asset} failed checksum or did not run"
    rm -f "$dest"
  else
    log "release asset ${asset} is not available"
  fi
  log "building the ${goos}/${GOARCH_NAME} CLI from ${ROOT}"
  if ! build_host_cli "$dest"; then
    die "CLI install failed. No usable release asset ${asset} from ${RELEASE_REPO} (set GITHUB_TOKEN or GH_TOKEN, or gh auth login), and building from the checkout failed."
  fi
  place_cli "$dest"
  log "installed a CLI built from the checkout to /usr/local/bin/dflow"
}

install_cli() {
  install_cli_release_or_build
}

resolve_chart() {
  CHART_REF="${ROOT}/packages/helm-chart"
  if [[ -n "$RELEASE_JSON" ]] && download_release_glob '^dflow-.+\.tgz$' /tmp/dflow-chart.tgz; then
    CHART_REF="/tmp/dflow-chart.tgz"
    log "using the Helm chart packaged in release ${RELEASE_TAG}"
    return 0
  fi
  if [[ -n "$RELEASE_JSON" ]]; then
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
ADMIN_USER=$(printf '%q' "$ADMIN_USER")
ADMIN_PASSWORD=$(printf '%q' "$ADMIN_PASSWORD")
IMAGE=$(printf '%q' "$IMAGE")
IMAGE_TAG=$(printf '%q' "$image_tag")
RELEASE_TAG=$(printf '%q' "${RELEASE_TAG:-}")
CHART_REF=$(printf '%q' "$CHART_REF")
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
certManager:
  install: false
  enabled: true
dflowUI:
  enabled: false
api:
  adminPassword: $(yaml_quote "$ADMIN_PASSWORD")
ingress:
  ingressClassName: traefik
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
  helm upgrade --install cert-manager "${ROOT}/packages/helm-chart/charts/cert-manager-v1.19.3.tgz" \
    --namespace cert-manager --create-namespace \
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
  local -a args=(-k -sS --max-time 20 -o /tmp/dflow-curl-body -w '%{http_code}')
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

self_test() {
  if [[ -z "${PUBLIC_IP:-}" ]]; then
    detect_public_ip || true
  fi
  if [[ -z "${TRAEFIK_HOST_IP:-}" ]] && command -v kubectl >/dev/null 2>&1 && [[ -r "${KUBECONFIG_PATH:-}" ]]; then
    TRAEFIK_HOST_IP="$(kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || true)"
  fi
  log "API health"
  if ! curl_health_ok "https://dflow.${DOMAIN}/ready" "http://dflow.${DOMAIN}/ready"; then
    kubectl -n dflow get ingress,certificate,pods >&2 || true
    kubectl -n kube-system get svc,pods -l app.kubernetes.io/name=traefik >&2 || true
    die "API health check failed. https://dflow.${DOMAIN}/ready and http://dflow.${DOMAIN}/ready did not return 200."
  fi

  log "CLI self-test"
  log "API https://dflow.${DOMAIN} user ${ADMIN_USER} password ${ADMIN_PASSWORD}"
  export PATH="/usr/local/bin:${PATH}"
  if ! dflow login -u "$ADMIN_USER" -p "$ADMIN_PASSWORD" --trust-ca "https://dflow.${DOMAIN}" </dev/null; then
    die "dflow login to https://dflow.${DOMAIN} failed. User ${ADMIN_USER}, password is the value printed below."
  fi

  if ! dflow namespace show "$SAMPLE_NAMESPACE" >/dev/null 2>&1; then
    dflow namespace create "$SAMPLE_NAMESPACE" </dev/null \
      || die "could not create namespace ${SAMPLE_NAMESPACE}"
  fi
  dflow target "$SAMPLE_NAMESPACE" </dev/null \
    || die "could not target namespace ${SAMPLE_NAMESPACE}"

  local app_list
  app_list="$(dflow app list -o json)" || die "dflow app list failed before the sample push"
  if app_exists "$app_list"; then
    log "removing leftover app ${SAMPLE_APP} from an earlier run"
    dflow app delete "$SAMPLE_APP" </dev/null \
      || die "could not delete leftover app ${SAMPLE_APP}"
  fi

  log "push ${SAMPLE_IMAGE} as ${SAMPLE_APP}"
  if ! printf '\n' | dflow push -n "$SAMPLE_APP" --container-image-url "$SAMPLE_IMAGE"; then
    kubectl -n "$SAMPLE_NAMESPACE" get pods,ingress >&2 || true
    dflow app logs --staging "$SAMPLE_APP" >&2 || true
    die "dflow push of ${SAMPLE_APP} failed"
  fi

  if ! curl_public_ok "https://${SAMPLE_APP}.${DOMAIN}/"; then
    kubectl -n "$SAMPLE_NAMESPACE" get pods,ingress >&2 || true
    die "https://${SAMPLE_APP}.${DOMAIN}/ did not return HTTP 200"
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
  log "self-test passed: login, push, HTTP 200, delete, and a clean namespace"
}

print_next() {
  local login_server login_mac api
  api="https://dflow.${DOMAIN}"
  login_server="$(printf 'dflow login -u %q -p %q --trust-ca %q' "$ADMIN_USER" "$ADMIN_PASSWORD" "$api")"
  login_mac="$login_server"
  cat <<EOF

dFlow is installed.

  API:       ${api}
  User:      ${ADMIN_USER}
  Password:  ${ADMIN_PASSWORD}
  Domain:    ${DOMAIN}

The installer already logged in, pushed ${SAMPLE_IMAGE}, checked HTTP 200,
deleted that app, and removed the ${SAMPLE_NAMESPACE} namespace.

On this server, repeat the check with docs/TESTING.md:

  export DOMAIN=${DOMAIN}
  ${login_server}

On a Mac, from a checkout of this repository:

  make dflow
  sudo install -m 0755 dist/dflow /usr/local/bin/dflow
  ${login_mac}

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
  [[ -n "${PUBLIC_IP:-}" ]] || die "the server public IP is empty, so the join URL cannot be printed"
  server="https://${PUBLIC_IP}:6443"
  cat <<EOF

Join a worker from another Ubuntu 22.04 or 24.04 machine. docs/INSTALL.md has the firewall ports.

  server: ${server}
  token:  ${token}

  sudo ./scripts/join-node.sh --server ${server} --token '${token}'

Print this again later with: sudo dflow join-info
EOF
}

main() {
  parse_args "$@"
  require_root
  require_checkout
  require_ubuntu
  detect_arch
  resolve_domain
  install_packages
  install_helm
  install_k3s
  apply_traefik
  verify_traefik
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
