#!/usr/bin/env bash
# Copy images/mirror.yaml into ghcr.io/dflow-sh/mirror.
# Uses REGISTRY_USER and REGISTRY_TOKEN (GITHUB_TOKEN in Actions).
# Three old-upstream images are read from MIRROR_DEX_SOURCE,
# MIRROR_UNPACKER_SOURCE, and MIRROR_KANIKO_SOURCE. Those references are
# not stored in git. If a variable is empty, the other images are still
# copied and this script exits 2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REGSYNC_VERSION="v0.11.7"
REGSYNC_SHA256="89aab06086fc42db0547e8d314d4e0e5646b1ffc6e499b76b3869c3addbb8736"

if ! command -v regsync >/dev/null 2>&1; then
  dest="${TMPDIR:-/tmp}/regsync-${REGSYNC_VERSION}"
  mkdir -p "$dest"
  if [[ ! -x "${dest}/regsync" ]]; then
    curl -fsSL -o "${dest}/regsync" \
      "https://github.com/regclient/regclient/releases/download/${REGSYNC_VERSION}/regsync-linux-amd64"
    echo "${REGSYNC_SHA256}  ${dest}/regsync" | sha256sum -c
    chmod 0755 "${dest}/regsync"
  fi
  export PATH="${dest}:${PATH}"
fi

CRANE_VERSION="v0.20.3"
CRANE_SHA256="36c67a932f489b3f2724b64af90b599a8ef2aa7b004872597373c0ad694dc059"
if ! command -v crane >/dev/null 2>&1; then
  dest="${TMPDIR:-/tmp}/crane-${CRANE_VERSION}"
  mkdir -p "$dest"
  if [[ ! -x "${dest}/crane" ]]; then
    tgz="$(mktemp)"
    curl -fsSL -o "$tgz" \
      "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz"
    echo "${CRANE_SHA256}  ${tgz}" | sha256sum -c
    tar -xzf "$tgz" -C "$dest" crane
    rm -f "$tgz"
    chmod 0755 "${dest}/crane"
  fi
  export PATH="${dest}:${PATH}"
fi

: "${REGISTRY_USER:?REGISTRY_USER is required}"
: "${REGISTRY_TOKEN:?REGISTRY_TOKEN is required}"
export REGISTRY_USER REGISTRY_TOKEN

missing=0
for name in MIRROR_DEX_SOURCE MIRROR_UNPACKER_SOURCE MIRROR_KANIKO_SOURCE; do
  if [[ -z "${!name:-}" ]]; then
    echo "mirror-sync: ${name} is empty. Set it to the old upstream namespace image reference. It is not stored in git." >&2
    missing=1
  fi
done

config="images/mirror.yaml"
if [[ "$missing" -eq 1 ]]; then
  config="$(mktemp)"
  python3 - "$config" <<'PY'
import pathlib, sys
text = pathlib.Path("images/mirror.yaml").read_text().splitlines(keepends=True)
out = []
skipping = False
for line in text:
    if line.startswith("  - source:") and "MIRROR_" in line:
        skipping = True
        continue
    if skipping:
        if line.startswith("  - source:"):
            skipping = "MIRROR_" in line
            if skipping:
                continue
        elif line.startswith("    ") or line.startswith("  #") or line.strip() == "":
            continue
        else:
            skipping = False
    out.append(line)
pathlib.Path(sys.argv[1]).write_text("".join(out))
PY
fi

# A token that can push to ghcr.io/dflow-sh is rejected by other public
# ghcr.io repositories. Those sources are pulled anonymously into an OCI
# layout, then pushed with the token. regsync copies the rest.
python3 - "$config" <<'PY'
import os, pathlib, re, subprocess, sys, tempfile

def expand_source(source):
    match = re.fullmatch(r"\{\{\s*env\s+\"([A-Z0-9_]+)\"\s*\}\}", source)
    if not match:
        return source
    return os.environ.get(match.group(1), "")

config = pathlib.Path(sys.argv[1]).read_text()
blocks = re.split(r"(?=^  - source:)", config, flags=re.M)
header = blocks[0]
body = []
ghcr_pairs = []
for block in blocks[1:]:
    source = block.splitlines()[0].split(":", 1)[1].strip().strip("'\"")
    source = expand_source(source)
    target = re.search(r"target:\s*(\S+)", block).group(1).strip("'\"")
    if not source:
        print(f"mirror-sync: empty source for {target}", file=sys.stderr)
        sys.exit(2)
    if source.startswith("ghcr.io/"):
        ghcr_pairs.append((source, target))
    else:
        body.append(block)

# Pull foreign ghcr.io images before any login. A push token is rejected
# by other public ghcr.io repositories.
subprocess.run(["crane", "auth", "logout", "ghcr.io"], check=False)
layout = pathlib.Path(tempfile.mkdtemp())
for source, target in ghcr_pairs:
    name = target.rsplit("/", 1)[-1].split(":", 1)[0]
    print(f"pull {target}", flush=True)
    subprocess.run(["crane", "copy", source, f"oci:{layout}:{name}"], check=True)

if body:
    regsync_path = pathlib.Path(tempfile.mkdtemp()) / "regsync.yaml"
    regsync_path.write_text(header + "".join(body))
    print(f"regsync once -c {regsync_path}", flush=True)
    subprocess.run(["regsync", "once", "-c", str(regsync_path)], check=True)

token = os.environ["REGISTRY_TOKEN"]
user = os.environ["REGISTRY_USER"]
login = subprocess.run(
    ["crane", "auth", "login", "ghcr.io", "-u", user, "--password-stdin"],
    input=token.encode(),
    check=False,
)
if login.returncode != 0:
    sys.exit(login.returncode)
for _source, target in ghcr_pairs:
    name = target.rsplit("/", 1)[-1].split(":", 1)[0]
    print(f"push {target}", flush=True)
    subprocess.run(["crane", "copy", f"oci:{layout}:{name}", target], check=True)
PY

python3 - <<'PY'
import json, os, pathlib, re, urllib.error, urllib.request

token = os.environ["REGISTRY_TOKEN"]
text = pathlib.Path("images/mirror.yaml").read_text()
names = []
for target in re.findall(r"target:\s*(\S+)", text):
    target = target.strip("'\"")
    path = target.split("/", 1)[1].split(":", 1)[0]
    names.append(path.split("/", 1)[1])

def request(method, url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as err:
        raw = err.read().decode()
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"message": raw[:200]}
        return err.code, payload

print("package\tvisibility")
for package in names:
    encoded = package.replace("/", "%2F")
    url = f"https://api.github.com/orgs/dflow-sh/packages/container/{encoded}"
    put_status, put_payload = request("PUT", url + "/visibility", {"visibility": "public"})
    status, payload = request("GET", url)
    visibility = payload.get("visibility") if isinstance(payload, dict) else None
    if visibility == "public":
        print(f"{package}\tpublic")
        continue
    message = ""
    if isinstance(put_payload, dict):
        message = put_payload.get("message") or ""
    print(f"{package}\tNOT_PUBLIC\tset_http={put_status}\tget_http={status}\t{message}")
PY

if [[ "$missing" -eq 1 ]]; then
  echo "mirror-sync: copied the images whose sources are in git. The three old-upstream images were not copied." >&2
  exit 2
fi
