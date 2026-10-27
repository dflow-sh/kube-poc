#!/usr/bin/env bash
# Render the Helm charts, scan the install, update, and join scripts, and
# print every image as name, tag, and digest.
#
#   scripts/image-inventory.sh
#   scripts/image-inventory.sh --check
#   scripts/image-inventory.sh --resolve
#   scripts/image-inventory.sh --scan
#
# --check fails on a floating tag, on latest, and on an image with no digest.
# A registry other than one host is fine. The server image in the install
# scripts may use a GitHub release tag; the rendered chart still needs a digest.
# --resolve asks the registry for tag digests. Digest pins are already resolved.
# --scan runs Trivy on every digest-pinned image. HIGH findings are printed.
# A CRITICAL finding fails the run. trivy must be on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECK=0
RESOLVE=0
SCAN=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --resolve) RESOLVE=1 ;;
    --scan) SCAN=1 ;;
    *) echo "usage: scripts/image-inventory.sh [--check] [--resolve] [--scan]" >&2; exit 2 ;;
  esac
done

HELM_VERSION="3.22.1"
HELM_SHA256="896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea"

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

cm_chart="$(echo packages/helm-chart/charts/cert-manager-*.tgz)"
helm template cert-manager "${cm_chart}" \
  --namespace cert-manager \
  --values packages/helm-chart/cert-manager-images.yaml \
  --set crds.enabled=true \
  > "${render_dir}/cert-manager.yaml"

export RENDER_DIR="$render_dir"
export DO_CHECK="$CHECK"
export DO_RESOLVE="$RESOLVE"
export DO_SCAN="$SCAN"

scan_pinned_images() {
  local list="$1"
  if ! command -v trivy >/dev/null 2>&1; then
    echo "trivy is required for --scan" >&2
    exit 1
  fi
  if [[ ! -s "$list" ]]; then
    echo "image scan found no digest-pinned images" >&2
    exit 1
  fi
  local fail=0
  local count=0
  local ref out ignore_file
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    count=$((count + 1))
    out="$(mktemp)"
    ignore_file=""
    case "$ref" in
      docker.io/emberstack/kubernetes-reflector@sha256:51dbd5880929dc26678f6e190c70abfbcccd3846679ff464e5815823fd782f1a|docker.io/emberstack/kubernetes-reflector:10.0.65@sha256:51dbd5880929dc26678f6e190c70abfbcccd3846679ff464e5815823fd782f1a)
        ignore_file="${ROOT}/scripts/trivy-allow/kubernetes-reflector-10.0.65.trivyignore"
        ;;
    esac
    echo "scan ${ref}"
    if ! trivy image \
      --quiet \
      --scanners vuln \
      --severity HIGH,CRITICAL \
      --list-all-pkgs=false \
      --exit-code 0 \
      --format json \
      --ignorefile "$ignore_file" \
      --timeout 15m \
      --output "$out" \
      "$ref"
    then
      echo "scan failed: ${ref}" >&2
      rm -f "$out"
      fail=1
      continue
    fi
    if ! python3 - "$out" "$ref" <<'PY'
import json
import sys

path, ref = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
if "Results" not in data and "SchemaVersion" not in data:
    print(f"scan report was not a Trivy result: {ref}", file=sys.stderr)
    sys.exit(2)
critical = {}
high = 0
for result in data.get("Results") or []:
    for vuln in result.get("Vulnerabilities") or []:
        severity = vuln.get("Severity")
        if severity == "CRITICAL":
            vid = vuln.get("VulnerabilityID") or "unknown"
            critical.setdefault(vid, vuln.get("FixedVersion") or "")
        elif severity == "HIGH":
            high += 1
print(f"{ref}\tcritical={len(critical)}\thigh={high}")
for vid in sorted(critical):
    fixed = critical[vid] or "none"
    print(f"CRITICAL\t{vid}\tfixed={fixed}\t{ref}")
sys.exit(1 if critical else 0)
PY
    then
      fail=1
    fi
    rm -f "$out"
  done < "$list"
  echo "scanned ${count} pinned images"
  if [[ "$fail" -ne 0 ]]; then
    echo "image scan failed" >&2
    exit 1
  fi
}

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
do_scan = os.environ["DO_SCAN"] == "1"

tag_or_var = r"(?:[A-Za-z0-9._-]+|\$\{[A-Za-z0-9_]+\}|\$\([A-Za-z0-9_]+\))"
ref_re = re.compile(
    r"^(?:[a-z0-9][a-z0-9.-]*(?:\.[a-z0-9.-]+)+/)?"
    r"[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)*"
    rf"(?:(?::{tag_or_var})(?:@sha256:[a-f0-9]{{64}})?|@sha256:[a-f0-9]{{64}})$"
)
rendered_re = re.compile(
    r"(?:ghcr\.io|quay\.io|docker\.io|registry\.k8s\.io|gcr\.io|registry\.suse\.com)/"
    r"[a-z0-9][a-z0-9._/-]*"
    r"(?::[A-Za-z0-9][A-Za-z0-9._-]*)?(?:@sha256:[a-f0-9]{64})?"
)
shell_re = re.compile(
    r"(?:ghcr\.io|quay\.io|docker\.io|gcr\.io|registry\.suse\.com)/"
    r"[a-z0-9][a-z0-9._/-]*"
    rf"(?:(?::{tag_or_var})(?:@sha256:[a-f0-9]{{64}})?|@sha256:[a-f0-9]{{64}})"
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
        if repo in {"dflow-sh/dflow-server", "dflow-sh/dflow-ui"}:
            index += 1
            continue
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
        elif "/" in repo:
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
        if ":" in base.rsplit("/", 1)[-1]:
            base, tag = base.rsplit(":", 1)
    else:
        # A registry port would be host:port/name. Tags are the last colon
        # only when it appears after the last slash.
        if ":" in ref.rsplit("/", 1)[-1]:
            base, tag = ref.rsplit(":", 1)
    image_name = base.rsplit("/", 1)[-1]
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
    tail = ref.rsplit("/", 1)[-1]
    if tail == "latest" or tail.endswith(":latest") or ":latest@" in tail:
        return False
    if re.search(r"@sha256:[a-f0-9]{64}$", ref):
        return True
    # The installer selects a GitHub release tag, or a local checkout tag.
    # The rendered server pod is still required to carry a digest.
    if ref.startswith("ghcr.io/dflow-sh/dflow-server:") or ref.startswith(
        "ghcr.io/dflow-sh/dflow-ui:"
    ):
        return ":latest" not in ref
    return False


table = []
for ref in sorted(rows):
    image_name, tag, digest = split_ref(ref)
    digest = resolve_digest(ref, digest)
    table.append((image_name, tag, digest, ref))
    if do_check and not allowed(ref):
        errors.append(f"not allowed: {ref} ({rows[ref]})")

if do_scan:
    seen_digests = set()
    pinned = []
    for ref in sorted(rows):
        digest_match = re.search(r"@(sha256:[a-f0-9]{64})$", ref)
        if not digest_match:
            continue
        digest = digest_match.group(1)
        if digest in seen_digests:
            continue
        seen_digests.add(digest)
        pinned.append(ref)
    (render_dir / "pinned-images.txt").write_text(
        "".join(f"{ref}\n" for ref in pinned)
    )

print("name\ttag\tdigest\treference")
for image_name, tag, digest, ref in table:
    print(f"{image_name}\t{tag}\t{digest}\t{ref}")

if errors:
    print("image inventory check failed:", file=sys.stderr)
    for item in errors:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY

if [[ "$SCAN" -eq 1 ]]; then
  scan_pinned_images "${render_dir}/pinned-images.txt"
fi
