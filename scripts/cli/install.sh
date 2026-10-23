#!/bin/sh
# Install the dflow CLI from a public GitHub release.
# This file stands alone. It does not read any other file from the repository.
set -eu

repo="dflow-sh/kube-poc"
base="https://github.com/${repo}/releases"
version="${DFLOW_VERSION:-latest}"
install_dir="${DFLOW_INSTALL_DIR:-}"
explicit_dir=0
use_sudo=0
sudo_mode="none"
path_hint=0

die() {
  echo "install.sh: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh
  curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh -s -- --version vX.Y.Z
  curl -fsSL https://github.com/dflow-sh/kube-poc/releases/latest/download/install.sh | sh -s -- --install-dir "$HOME/.local/bin"

Options:
  --version <tag>       Release tag, or latest. Default: latest, or $DFLOW_VERSION.
  --install-dir <dir>   Directory for the dflow binary. Default: /usr/local/bin when
                        that directory is writable, passwordless sudo works, or
                        you accept sudo on /dev/tty. Otherwise ~/.local/bin.
                        $DFLOW_INSTALL_DIR is the same default when this flag
                        is omitted.
  -h, --help            Show this help.

The script downloads dflow-<os>-<arch> (linux or darwin, amd64 or arm64) and
checks SHA256 against checksums.txt in that release. It sends no token.
A missing asset or a checksum mismatch exits non-zero. Running it again
replaces the binary. At the end it runs dflow version and prints the next
step: dflow login.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die "--version needs a release tag, or latest"
      version=$2
      shift 2
      ;;
    --version=*)
      version=${1#--version=}
      [ -n "$version" ] || die "--version needs a release tag, or latest"
      shift
      ;;
    --install-dir)
      [ $# -ge 2 ] || die "--install-dir needs a directory"
      install_dir=$2
      explicit_dir=1
      shift 2
      ;;
    --install-dir=*)
      install_dir=${1#--install-dir=}
      [ -n "$install_dir" ] || die "--install-dir needs a directory"
      explicit_dir=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [ $# -eq 0 ] || die "unexpected argument: $1"
      break
      ;;
    *)
      die "unknown argument: $1 (see --help)"
      ;;
  esac
done

if [ -n "${DFLOW_INSTALL_DIR:-}" ] && [ "$explicit_dir" -eq 0 ]; then
  explicit_dir=1
fi

if [ -z "$version" ]; then
  version=latest
fi
case "$version" in
  *[!A-Za-z0-9._+-]*)
    die "invalid version: ${version}"
    ;;
esac

os_name=$(uname -s)
case "$os_name" in
  Linux) goos=linux ;;
  Darwin) goos=darwin ;;
  *)
    die "unsupported OS: ${os_name}. This installer supports linux and darwin."
    ;;
esac

mach=$(uname -m)
case "$mach" in
  x86_64|amd64) goarch=amd64 ;;
  aarch64|arm64) goarch=arm64 ;;
  *)
    die "unsupported architecture: ${mach}. This installer supports amd64 and arm64."
    ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
if command -v sha256sum >/dev/null 2>&1; then
  hash_kind=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  hash_kind=shasum
else
  die "sha256sum or shasum is required"
fi

asset="dflow-${goos}-${goarch}"
if [ "$version" = "latest" ]; then
  prefix="${base}/latest/download"
else
  prefix="${base}/download/${version}"
fi
bin_url="${prefix}/${asset}"
sum_url="${prefix}/checksums.txt"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

download() {
  _url=$1
  _dest=$2
  if ! curl -fsSL --proto '=https' --retry 3 --retry-delay 1 -o "$_dest" "$_url"; then
    die "could not download ${_url} (missing release asset or network error)"
  fi
  if [ ! -s "$_dest" ]; then
    die "download was empty: ${_url}"
  fi
}

file_sha256() {
  _sum_line=""
  if [ "$hash_kind" = "sha256sum" ]; then
    _sum_line=$(sha256sum "$1") || die "sha256sum failed for $1"
  else
    _sum_line=$(shasum -a 256 "$1") || die "shasum failed for $1"
  fi
  set -f
  # shellcheck disable=SC2086
  set -- $_sum_line
  set +f
  printf '%s\n' "$1" | tr 'ABCDEF' 'abcdef'
}

checksum_for() {
  _asset_name=$1
  _sum_file=$2
  _cr=$(printf '\r')
  _found=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=${_line%"$_cr"}
    case "$_line" in
      ''|'#'*) continue ;;
    esac
    set -f
    # shellcheck disable=SC2086
    set -- $_line
    set +f
    _hash=$1
    _name=${_line##* }
    _name=${_name#\*}
    if [ "$_name" = "$_asset_name" ]; then
      _found=$_hash
      break
    fi
  done < "$_sum_file"
  if [ -z "$_found" ]; then
    die "checksums.txt has no SHA256 for ${_asset_name}"
  fi
  case "$_found" in
    *[!0-9A-Fa-f]*)
      die "checksum for ${_asset_name} is not SHA256"
      ;;
  esac
  if [ "${#_found}" -ne 64 ]; then
    die "checksum for ${_asset_name} is not SHA256"
  fi
  printf '%s\n' "$_found" | tr 'ABCDEF' 'abcdef'
}

can_write_dir() {
  _dir=$1
  if [ -d "$_dir" ]; then
    [ -w "$_dir" ]
    return
  fi
  while [ ! -d "$_dir" ]; do
    _next=$(dirname "$_dir")
    if [ "$_next" = "$_dir" ]; then
      return 1
    fi
    _dir=$_next
  done
  [ -w "$_dir" ]
}

sudo_ok() {
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true >/dev/null 2>&1
}

# Ask on /dev/tty so curl | sh can still prompt. Decline, or no tty, returns 1.
# [ -r /dev/tty ] is the mode-bit check. Open must also succeed: a device node
# can be mode-readable when this process has no controlling terminal.
sudo_prompt() {
  [ -r /dev/tty ] || return 1
  if ! (: </dev/tty) >/dev/null 2>&1; then
    return 1
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  printf 'Install dflow to /usr/local/bin using sudo? [y/N] ' >/dev/tty || return 1
  _answer=""
  if ! IFS= read -r _answer </dev/tty; then
    return 1
  fi
  case "$_answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_privileged() {
  _rc=0
  if [ "$use_sudo" -ne 1 ]; then
    "$@" || _rc=$?
  elif [ "$sudo_mode" = "tty" ]; then
    # The redirect is sudo's stdin. /dev/tty is the terminal under curl | sh.
    # shellcheck disable=SC2024
    sudo "$@" </dev/tty || _rc=$?
  else
    sudo -n "$@" || _rc=$?
  fi
  return "$_rc"
}

download "$sum_url" "$tmp/checksums.txt"
download "$bin_url" "$tmp/$asset"

want=$(checksum_for "$asset" "$tmp/checksums.txt") || exit 1
got=$(file_sha256 "$tmp/$asset") || exit 1
if [ "$want" != "$got" ]; then
  echo "install.sh: SHA256 mismatch for ${asset}" >&2
  echo "expected ${want}" >&2
  echo "actual   ${got}" >&2
  exit 1
fi

if [ "$explicit_dir" -eq 0 ]; then
  if can_write_dir /usr/local/bin; then
    install_dir=/usr/local/bin
  elif sudo_ok; then
    install_dir=/usr/local/bin
    use_sudo=1
    sudo_mode="noninteractive"
  elif sudo_prompt; then
    install_dir=/usr/local/bin
    use_sudo=1
    sudo_mode="tty"
  else
    if [ -z "${HOME:-}" ]; then
      die "HOME is not set, and /usr/local/bin is not writable"
    fi
    install_dir="${HOME}/.local/bin"
    path_hint=1
  fi
elif ! can_write_dir "$install_dir"; then
  if sudo_ok; then
    use_sudo=1
    sudo_mode="noninteractive"
  else
    die "cannot write ${install_dir}"
  fi
fi

dest="${install_dir}/dflow"
dest_dir=$(dirname "$dest")
run_privileged mkdir -p "$dest_dir" || die "could not create ${dest_dir}"
if command -v install >/dev/null 2>&1; then
  run_privileged install -m 0755 "$tmp/$asset" "$dest" || die "could not install ${dest}"
else
  run_privileged cp "$tmp/$asset" "$dest" || die "could not copy ${dest}"
  run_privileged chmod 0755 "$dest" || die "could not chmod ${dest}"
fi

if [ "$goos" = "darwin" ] && command -v xattr >/dev/null 2>&1; then
  run_privileged xattr -d com.apple.quarantine "$dest" 2>/dev/null || true
fi

if [ "$path_hint" -eq 1 ]; then
  echo "Installed ${dest}"
  echo "Add ${install_dir} to PATH:"
  echo "  export PATH=\"${install_dir}:\$PATH\""
else
  echo "Installed ${dest}"
fi

resolved=$(command -v dflow 2>/dev/null || true)
if [ -n "$resolved" ] && [ "$resolved" != "$dest" ]; then
  echo "warning: dflow on PATH is ${resolved}, but this install wrote ${dest}" >&2
fi

"$dest" version
echo "Next step: dflow login"
