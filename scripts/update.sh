#!/usr/bin/env bash
# Upgrade a dFlow server installed by scripts/install.sh, or replace the local CLI.
# See docs/INSTALL.md.
set -euo pipefail

SCRIPT_NAME=update.sh
# shellcheck source=install.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"

usage() {
  cat <<'EOF'
Usage:
  sudo --preserve-env=GITHUB_TOKEN ./scripts/update.sh
  sudo --preserve-env=GITHUB_TOKEN ./scripts/update.sh v1.0.0
  ./scripts/update.sh --cli
  ./scripts/update.sh --cli v1.0.0

The server form runs helm upgrade to the latest GitHub Release, or to the
tag you pass. It waits until dflow-server is ready, then repeats the API
health check and CLI self-test from scripts/install.sh.

--cli replaces /usr/local/bin/dflow on this Mac or Linux machine.

GITHUB_TOKEN, GH_TOKEN, or an authenticated gh session downloads private
release assets. Without that, the CLI and server image are built from this
checkout. A tag you name that does not exist is an error.
EOF
}

REQUESTED=""
CLI_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli)
      CLI_ONLY=1
      shift
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version needs a value such as v1.0.0"
      REQUESTED="$2"
      shift 2
      ;;
    --version=*)
      REQUESTED="${1#--version=}"
      shift
      ;;
    latest)
      REQUESTED=""
      shift
      ;;
    -h|--help)
      usage
      trap - ERR
      exit 0
      ;;
    v*)
      REQUESTED="$1"
      shift
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

require_checkout
detect_arch

if [[ "$CLI_ONLY" -eq 1 ]]; then
  if [[ -n "$REQUESTED" ]]; then
    load_release_json "$REQUESTED" \
      || die "GitHub release ${REQUESTED} was not found. Set GITHUB_TOKEN or GH_TOKEN, or run gh auth login."
  else
    RELEASE_TAG_REQUEST=latest
  fi
  install_cli_release_or_build
  log "CLI updated: /usr/local/bin/dflow"
  trap - ERR
  exit 0
fi

require_root
export KUBECONFIG="$KUBECONFIG_PATH"
[[ -r "$KUBECONFIG_PATH" ]] || die "k3s kubeconfig ${KUBECONFIG_PATH} is missing. Run scripts/install.sh first."
[[ -f "${STATE_DIR}/install.env" ]] || die "${STATE_DIR}/install.env is missing. Run scripts/install.sh first."
# shellcheck disable=SC1091
source "${STATE_DIR}/install.env"

if [[ -n "$REQUESTED" ]]; then
  load_release_json "$REQUESTED" \
    || die "GitHub release ${REQUESTED} was not found. Set GITHUB_TOKEN or GH_TOKEN, or run gh auth login. Refusing to build a different tree and call it ${REQUESTED}."
else
  RELEASE_TAG_REQUEST=latest
  load_release_json latest || log "no latest GitHub release; upgrading from this checkout"
fi

install_packages
install_helm
import_or_build_image
install_cli
kubectl -n cert-manager get deploy cert-manager-webhook >/dev/null 2>&1 \
  || die "cert-manager is not installed. Run scripts/install.sh."
apply_dflow_release
self_test
log "upgrade finished for https://dflow.${DOMAIN} (image ${IMAGE})"
trap - ERR
