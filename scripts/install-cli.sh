#!/usr/bin/env bash
# Install the dflow CLI on a Mac or Linux workstation.
# The binary is placed at /usr/local/bin/dflow.
# See docs/INSTALL.md.
set -euo pipefail

SCRIPT_NAME=install-cli.sh
# shellcheck source=install.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"

API=""
REQUESTED=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/install-cli.sh --api https://dflow.<domain> --user admin --password 'password'
  ./scripts/install-cli.sh --api https://paas.dflow.sh --apps-domain apps.dflow.sh
  GITHUB_TOKEN=... ./scripts/install-cli.sh --api https://dflow.<domain>
  ./scripts/install-cli.sh --version v1.0.0 --api https://dflow.<domain>
  ./scripts/install-cli.sh --from-checkout

Installs the darwin or linux CLI for this CPU to /usr/local/bin/dflow.
A GitHub Release asset is used when GITHUB_TOKEN, GH_TOKEN, or gh auth login
can read the private repository. If that asset cannot be downloaded, the
script exits non-zero. --from-checkout builds from this checkout with go build.

When --api is set, the script logs in, pushes traefik/whoami, checks HTTP 200,
deletes the app, and deletes the sample namespace. Without --api it prints
those commands and does not run them.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api)
      [[ $# -ge 2 ]] || die "--api needs the dFlow API URL"
      API="$2"
      shift 2
      ;;
    --api=*)
      API="${1#--api=}"
      shift
      ;;
    --apps-domain)
      [[ $# -ge 2 ]] || die "--apps-domain needs a hostname such as apps.dflow.sh"
      APPS_DOMAIN="$2"
      shift 2
      ;;
    --apps-domain=*)
      APPS_DOMAIN="${1#--apps-domain=}"
      shift
      ;;
    --user)
      [[ $# -ge 2 ]] || die "--user needs a value"
      ADMIN_USER="$2"
      shift 2
      ;;
    --user=*)
      ADMIN_USER="${1#--user=}"
      shift
      ;;
    --password)
      [[ $# -ge 2 ]] || die "--password needs a value"
      ADMIN_PASSWORD="$2"
      shift 2
      ;;
    --password=*)
      ADMIN_PASSWORD="${1#--password=}"
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

require_checkout
detect_arch
if [[ "$FROM_CHECKOUT" -eq 1 && -n "$REQUESTED" ]]; then
  die "--from-checkout cannot be combined with --version"
fi
if [[ "$FROM_CHECKOUT" -eq 1 ]]; then
  log "CLI will be built from this checkout (--from-checkout)"
elif [[ -n "$REQUESTED" ]]; then
  load_release_json "$REQUESTED" \
    || die "GitHub release ${REQUESTED} was not found. Set GITHUB_TOKEN or GH_TOKEN, or run gh auth login. Refusing to build the checkout CLI."
else
  RELEASE_TAG_REQUEST=latest
fi
install_cli_release_or_build

if [[ -z "$API" ]]; then
  cat <<EOF
Installed /usr/local/bin/dflow.

Login and the sample push were not run. Pass --api to run them, or run:

  dflow login -u ${ADMIN_USER} -p '<password>' --trust-ca "https://dflow.<domain>"
  dflow namespace create sample
  dflow target sample
  dflow push -n hello --container-image-url traefik/whoami
  curl -k -sS -D - "https://hello.<domain>/" -o /tmp/whoami-body | head -n 1
  dflow app delete hello
  dflow namespace delete sample -f
EOF
  trap - ERR
  exit 0
fi

host="${API#https://}"
host="${host#http://}"
host="${host%%/*}"
API_HOST="$host"
if [[ -n "${APPS_DOMAIN:-}" ]]; then
  APPS_BASE="$APPS_DOMAIN"
elif [[ "$host" == dflow.* ]]; then
  APPS_BASE="${host#dflow.}"
else
  die "pass --apps-domain when the API host is not dflow.<apps-domain>"
fi
DOMAIN="$APPS_BASE"
export PATH="/usr/local/bin:${PATH}"
self_test
log "CLI installed at /usr/local/bin/dflow and the sample push against ${API} passed"
trap - ERR
