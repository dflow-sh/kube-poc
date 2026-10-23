#!/usr/bin/env bash
# Upgrade a dFlow server installed by scripts/install.sh.
# See docs/INSTALL.md.
set -euo pipefail

SCRIPT_NAME=update.sh
# shellcheck source=install.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"

usage() {
  cat <<'EOF'
Usage:
  sudo ./scripts/update.sh
  sudo ./scripts/update.sh v0.0.4
  sudo ./scripts/update.sh --from-checkout

Runs helm upgrade to the latest GitHub Release, or to the tag you pass.
Replaces /usr/local/bin/dflow with that same release before the server
upgrade. Checks the CLI SHA256 against checksums.txt. No token is sent.
Waits until dflow-server is ready, then repeats the API health check and
CLI self-test from scripts/install.sh.

The server image is pulled from ghcr.io. If that pull fails, the script
exits non-zero. It does not reuse or build a checkout image.
--from-checkout is the only way to upgrade from this checkout.
A tag you name that does not exist is an error.
EOF
}

REQUESTED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --from-checkout)
      FROM_CHECKOUT=1
      shift
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

if [[ "$FROM_CHECKOUT" -eq 1 && -n "$REQUESTED" ]]; then
  die "--from-checkout cannot be combined with a release tag"
fi

require_checkout
detect_arch
require_root
export KUBECONFIG="$KUBECONFIG_PATH"
[[ -r "$KUBECONFIG_PATH" ]] || die "k3s kubeconfig ${KUBECONFIG_PATH} is missing. Run scripts/install.sh first."
[[ -f "${STATE_DIR}/install.env" ]] || die "${STATE_DIR}/install.env is missing. Run scripts/install.sh first."
# shellcheck disable=SC1091
source "${STATE_DIR}/install.env"
# A v0.0.4 install leaves values.yaml world-readable. Tighten it before the
# upgrade, and again after the chart values are rewritten.
restrict_values_file
# A v0.0.4 install.env stores ADMIN_PASSWORD=password. Drop that, and changeme,
# before apply_dflow_release writes the chart values.
replace_known_default_passwords

if [[ "$FROM_CHECKOUT" -eq 1 ]]; then
  log "upgrading from this checkout (--from-checkout)"
elif [[ -n "$REQUESTED" ]]; then
  load_release_json "$REQUESTED" \
    || die "GitHub release ${REQUESTED} was not found. Refusing to build a different tree and call it ${REQUESTED}."
else
  RELEASE_TAG_REQUEST=latest
  load_release_json latest \
    || die "no GitHub release was found for ${RELEASE_REPO}. Refusing to build this checkout. Pass --from-checkout to build it."
fi

install_packages
install_helm
install_cli_release_or_build
import_or_build_image
kubectl -n cert-manager get deploy cert-manager-webhook >/dev/null 2>&1 \
  || die "cert-manager is not installed. Run scripts/install.sh."
apply_dflow_release
restrict_values_file
self_test
log "upgrade finished for https://${API_HOST:-dflow.${DOMAIN}} (image ${IMAGE})"
trap - ERR
