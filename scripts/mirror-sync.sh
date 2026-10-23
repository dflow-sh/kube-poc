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

REGCTL_VERSION="v0.11.7"
REGCTL_SHA256="3737fbbdd791e04e7a831640b681f3397a376498e80e2ad9b1b2d27296f239bc"
if ! command -v regctl >/dev/null 2>&1; then
  dest="${TMPDIR:-/tmp}/regctl-${REGCTL_VERSION}"
  mkdir -p "$dest"
  if [[ ! -x "${dest}/regctl" ]]; then
    curl -fsSL -o "${dest}/regctl" \
      "https://github.com/regclient/regclient/releases/download/${REGCTL_VERSION}/regctl-linux-amd64"
    echo "${REGCTL_SHA256}  ${dest}/regctl" | sha256sum -c
    chmod 0755 "${dest}/regctl"
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
# Isolate registry config so a push token is not sent on the anonymous pull.
export XDG_CONFIG_HOME="$(mktemp -d)"
export DOCKER_CONFIG="$(mktemp -d)"
set +e
python3 - "$config" <<'PY'
import os, pathlib, re, subprocess, sys, tempfile, time

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
# by other public ghcr.io repositories. The layout keeps the manifest
# digest, including multi-arch indexes.
layout = pathlib.Path(tempfile.mkdtemp())
for source, target in ghcr_pairs:
    name = target.rsplit("/", 1)[-1].split(":", 1)[0]
    print(f"pull {target}", flush=True)
    subprocess.run(
        ["regctl", "image", "copy", source, f"ocidir://{layout}:{name}"],
        check=True,
    )

regsync_failed = False
if body:
    regsync_path = pathlib.Path(tempfile.mkdtemp()) / "regsync.yaml"
    regsync_path.write_text(header + "".join(body))
    # A manifest put can be denied while blobs are still landing. Retry the
    # whole sync; images already present are left alone.
    for attempt in range(1, 4):
        print(f"regsync once -c {regsync_path} attempt {attempt}", flush=True)
        result = subprocess.run(["regsync", "once", "-c", str(regsync_path)])
        if result.returncode == 0:
            regsync_failed = False
            break
        regsync_failed = True
        print(f"regsync exited {result.returncode}", file=sys.stderr, flush=True)
        time.sleep(10)

token = os.environ["REGISTRY_TOKEN"]
user = os.environ["REGISTRY_USER"]
login = subprocess.run(
    ["regctl", "registry", "login", "ghcr.io", "-u", user, "--pass-stdin"],
    input=token.encode(),
    check=False,
)
if login.returncode != 0:
    sys.exit(login.returncode)
for _source, target in ghcr_pairs:
    name = target.rsplit("/", 1)[-1].split(":", 1)[0]
    pushed = False
    for attempt in range(1, 4):
        print(f"push {target} attempt {attempt}", flush=True)
        result = subprocess.run(
            ["regctl", "image", "copy", f"ocidir://{layout}:{name}", target],
        )
        if result.returncode == 0:
            pushed = True
            break
        print(f"push {target} exited {result.returncode}", file=sys.stderr, flush=True)
        time.sleep(10)
    if not pushed:
        sys.exit(1)
if regsync_failed:
    sys.exit(1)
PY
copy_status=$?
set -e

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
fi
if [[ "${copy_status:-0}" -ne 0 ]]; then
  exit "$copy_status"
fi
