#!/usr/bin/env bash
# Render the Helm charts, scan the install, update, and join scripts, and
# print every image as name, tag, and digest.
#
#   scripts/image-inventory.sh
#   scripts/image-inventory.sh --check
#   scripts/image-inventory.sh --resolve
#
# --check fails unless each image is either ghcr.io/dflow-sh/mirror/<name>@sha256:<digest>
# or another ghcr.io/dflow-sh image (the server and UI tags).
# --resolve asks the registry for tag digests. Digest pins are already resolved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECK=0
RESOLVE=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --resolve) RESOLVE=1 ;;
    *) echo "usage: scripts/image-inventory.sh [--check] [--resolve]" >&2; exit 2 ;;
  esac
done

HELM_VERSION="3.19.0"
HELM_SHA256="a7f81ce08007091b86d8bd696eb4d86b8d0f2e1b9f6c714be62f82f96a594496"

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    local ver
    ver="$(helm version --template '{{.Version}}' 2>/dev/null || true)"
    ver="${ver#v}"
    local major minor
    major="${ver%%.*}"
    minor="${ver#*.}"
    minor="${minor%%.*}"
    if [[ "$major" -gt 3 || ( "$major" -eq 3 && "$minor" -ge 17 ) ]]; then
      return 0
    fi
  fi
  local dest="${TMPDIR:-/tmp}/helm-${HELM_VERSION}"
  if [[ ! -x "${dest}/helm" ]]; then
    mkdir -p "$dest"
    local tgz
    tgz="$(mktemp)"
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o "$tgz"
    echo "${HELM_SHA256}  ${tgz}" | sha256sum -c
    tar -xzf "$tgz" -C "$dest" --strip-components=1 linux-amd64/helm
    rm -f "$tgz"
  fi
  export PATH="${dest}:${PATH}"
}

ensure_helm

render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

helm template dflow packages/helm-chart \
  --namespace dflow \
  --set global.domain=example.com \
  > "${render_dir}/dflow.yaml"

helm template cert-manager packages/helm-chart/charts/cert-manager-v1.19.3.tgz \
  --namespace cert-manager \
  --values packages/helm-chart/cert-manager-images.yaml \
  --set crds.enabled=true \
  > "${render_dir}/cert-manager.yaml"

export RENDER_DIR="$render_dir"
export DO_CHECK="$CHECK"
export DO_RESOLVE="$RESOLVE"

python3 - <<'PY'
import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(".").resolve()
render_dir = pathlib.Path(os.environ["RENDER_DIR"])
do_check = os.environ["DO_CHECK"] == "1"
do_resolve = os.environ["DO_RESOLVE"] == "1"

ref_re = re.compile(
    r"^(?:[a-z0-9][a-z0-9.-]*(?:\.[a-z0-9.-]+)+/)?"
    r"[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)*"
    r"(?::(?:[A-Za-z0-9._-]+|\$\{[A-Za-z0-9_]+\}|\$\([A-Za-z0-9_]+\))|@sha256:[a-f0-9]{64})$"
)
rendered_re = re.compile(
    r"(?:ghcr\.io|quay\.io|docker\.io|registry\.k8s\.io)/"
    r"[a-z0-9][a-z0-9._/-]*"
    r"(?::[A-Za-z0-9][A-Za-z0-9._-]*|@sha256:[a-f0-9]{64})"
)
shell_re = re.compile(
    r"(?:ghcr\.io|quay\.io|docker\.io)/"
    r"[a-z0-9][a-z0-9._/-]*"
    r"(?::(?:[A-Za-z0-9._-]+|\$\{[A-Za-z0-9_]+\}|\$\([A-Za-z0-9_]+\))|@sha256:[a-f0-9]{64})"
)

rows = {}
errors = []


def consider(raw, origin):
    ref = raw.strip().strip("'\"")
    if ref and not ref_re.match(ref):
        while ref and ref[-1] in ");," and not ref_re.match(ref):
            ref = ref[:-1]
    if not ref or ref in {"*", ">-", "|-", "|"}:
        return
    if "*" in ref or " " in ref or ref.startswith("http"):
        return
    if not ref_re.match(ref):
        return
    # railpack is a build mode name, not a container image.
    if ref == "railpack":
        return
    rows.setdefault(ref, origin)


def from_rendered(text):
    for found in rendered_re.findall(text):
        consider(found, "render")


def from_shell(path):
    text = path.read_text()
    for match in shell_re.finditer(text):
        consider(match.group(0), path.name)


def from_values(path):
    lines = path.read_text().splitlines()
    index = 0
    while index < len(lines):
        repo_match = re.match(r"^(\s*)repository:\s*(\S+)\s*$", lines[index])
        if not repo_match:
            index += 1
            continue
        indent = len(repo_match.group(1))
        repo = repo_match.group(2).strip("'\"")
        tag = ""
        digest = ""
        cursor = index + 1
        while cursor < len(lines):
            follow = lines[cursor]
            if not follow.strip() or follow.strip().startswith("#"):
                cursor += 1
                continue
            follow_indent = len(follow) - len(follow.lstrip(" "))
            if follow_indent < indent:
                break
            follow_match = re.match(r"^\s*(tag|digest):\s*(\S+)\s*$", follow)
            if follow_indent == indent and follow_match:
                value = follow_match.group(2).strip("'\"")
                if follow_match.group(1) == "tag":
                    tag = value
                else:
                    digest = value
                cursor += 1
                continue
            if follow_indent == indent:
                break
            cursor += 1
        if repo.endswith("@sha256") and re.fullmatch(r"[a-f0-9]{64}", tag):
            consider(f"{repo}:{tag}", path.name)
        elif "mirror/" in repo or repo.startswith("ghcr.io/dflow-sh/"):
            if digest:
                if not digest.startswith("sha256:"):
                    digest = "sha256:" + digest
                consider(f"{repo}@{digest}", path.name)
            elif tag:
                consider(f"{repo}:{tag}", path.name)
        index = max(cursor, index + 1)


for rendered in sorted(render_dir.glob("*.yaml")):
    from_rendered(rendered.read_text())

for name in ("install.sh", "update.sh", "join-node.sh"):
    from_shell(root / "scripts" / name)

from_values(root / "packages/helm-chart/values.yaml")
from_values(root / "packages/helm-chart/cert-manager-images.yaml")

# Dex, reflector, and SeaweedFS encode the pin as repository@sha256 plus a
# hex tag. The rendered manifest is the source of truth for those.

mirror_targets = {}
mirror_text = (root / "images/mirror.yaml").read_text()
for target in re.findall(r"^\s*target:\s*(\S+)\s*$", mirror_text, re.M):
    target = target.strip("'\"")
    image_name, _, tag = target.rsplit("/", 1)[-1].partition(":")
    mirror_targets[image_name] = tag

digest_re = re.compile(r"^(.+)@(?P<digest>sha256:[a-f0-9]{64})$")
tag_re = re.compile(r"^(?P<name>.+):(?P<tag>[^:]+)$")


def split_ref(ref):
    digest = ""
    tag = ""
    base = ref
    pinned = digest_re.match(ref)
    if pinned:
        base = pinned.group(1)
        digest = pinned.group("digest")
    else:
        # A registry port would be host:port/name. Tags are the last colon
        # only when it appears after the last slash.
        if ":" in ref.rsplit("/", 1)[-1]:
            base, tag = ref.rsplit(":", 1)
    image_name = base.rsplit("/", 1)[-1]
    if not tag and image_name in mirror_targets:
        tag = mirror_targets[image_name]
    return image_name, tag, digest


def resolve_digest(ref, digest):
    if digest:
        return digest
    if not do_resolve:
        return "unresolved"
    crane = "crane"
    try:
        out = subprocess.run(
            [crane, "digest", ref],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unresolved"
    return out.stdout.strip() or "unresolved"


def allowed(ref):
    if ref.startswith("ghcr.io/dflow-sh/mirror/"):
        return "@sha256:" in ref and bool(re.search(r"@sha256:[a-f0-9]{64}$", ref))
    if ref.startswith("ghcr.io/dflow-sh/"):
        rest = ref[len("ghcr.io/dflow-sh/") :]
        # Product images keep moving tags. The mirror path is handled above.
        return not rest.startswith("mirror/")
    return False


table = []
for ref in sorted(rows):
    image_name, tag, digest = split_ref(ref)
    digest = resolve_digest(ref, digest)
    table.append((image_name, tag, digest, ref))
    if do_check and not allowed(ref):
        errors.append(f"not allowed: {ref} ({rows[ref]})")

if do_check:
    seen_names = {name for name, _, _, _ in table}
    for image_name in sorted(mirror_targets):
        if image_name not in seen_names:
            errors.append(f"mirror target {image_name} is not in the inventory")
    for image_name, tag, digest, ref in table:
        if ref.startswith("ghcr.io/dflow-sh/mirror/") and image_name not in mirror_targets:
            errors.append(f"inventory image {image_name} has no images/mirror.yaml target")

print("name\ttag\tdigest\treference")
for image_name, tag, digest, ref in table:
    print(f"{image_name}\t{tag}\t{digest}\t{ref}")

if errors:
    print("image inventory check failed:", file=sys.stderr)
    for item in errors:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY
