#!/usr/bin/env bash
# Fail when product version strings disagree with packages/dflow/version/version.go
# or when /info's default builder is no longer railpack.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(".").resolve()
errors = []

def read(rel):
    path = root / rel
    if not path.is_file():
        errors.append(f"missing {rel}")
        return ""
    return path.read_text()

def must_contain(rel, snippet):
    text = read(rel)
    if snippet not in text:
        errors.append(f"{rel} does not contain {snippet!r}")
    return text

version_go = read("packages/dflow/version/version.go")
found = re.findall(r'var (?:Version|ChartVersion) = "([^"]+)"', version_go)
if found != ["v0.0.0-dev", "v0.0.0-dev"]:
    errors.append(f"version.go defaults are {found!r}, want both v0.0.0-dev")
version = "v0.0.0-dev"
chart_version = version[1:]

chart = read("packages/helm-chart/Chart.yaml")
app_version = None
chart_ver = None
for line in chart.splitlines():
    if line.startswith("appVersion: "):
        app_version = line.split(": ", 1)[1].strip()
    elif line.startswith("version: "):
        chart_ver = line.split(": ", 1)[1].strip()
if app_version != version:
    errors.append(f"Chart.yaml appVersion is {app_version!r}, want {version!r}")
if chart_ver != chart_version:
    errors.append(f"Chart.yaml version is {chart_ver!r}, want {chart_version!r}")

values = read("packages/helm-chart/values.yaml")

def image_tag(text, name):
    match = re.search(
        rf"^  {re.escape(name)}:\n(?:    .*\n)*?    tag: (\S+)\s*$",
        text,
        re.M,
    )
    return match.group(1) if match else None

for image_name in ("dflow", "dflow-ui"):
    tag = image_tag(values, image_name)
    if tag != version:
        errors.append(f"values image.{image_name}.tag is {tag!r}, want {version!r}")

if not re.search(r"^  defaultBuilderImage: railpack\s*$", values, re.M):
    errors.append("values server.defaultBuilderImage is not railpack")
if not re.search(r"^  defaultBuildMode: railpack\s*$", values, re.M):
    errors.append("values server.defaultBuildMode is not railpack")

server_tpl = read("packages/helm-chart/templates/server.yaml")
if 'value: {{ .Values.server.defaultBuilderImage | default "railpack" | quote }}' not in server_tpl:
    errors.append("server template DEFAULT_BUILDER_IMAGE does not default to railpack")
builder_env = server_tpl.split("DEFAULT_BUILDER_IMAGE", 1)
if len(builder_env) != 2 or "image.builder" in builder_env[1].split("\n", 2)[1]:
    errors.append("DEFAULT_BUILDER_IMAGE still uses image.builder")

builder_tpl = read("packages/helm-chart/templates/default-builderimage.yaml")
if 'image: {{ .Values.server.defaultBuilderImage | default "railpack" | quote }}' not in builder_tpl:
    errors.append("default BuilderImage does not use server.defaultBuilderImage")

swagger = json.loads(read("docs/references/api/swagger.json") or "{}")
info_version = (swagger.get("info") or {}).get("version")
if info_version != version:
    errors.append(f"swagger info.version is {info_version!r}, want {version!r}")

must_contain("packages/dflow/api/v1/docs/docs.go", f"Version: {version}")
must_contain("README.md", f"Unreleased builds report `{version}`")
must_contain("docs/INSTALL.md", f"ghcr.io/dflow-sh/dflow-server:{version}")
must_contain("scripts/install.sh", f'DFLOW_VERSION="${{DFLOW_VERSION:-{version}}}"')
must_contain("scripts/e2e-smoke.sh", f"ghcr.io/dflow-sh/dflow-server:{version}")
must_contain(".github/workflows/ci.yml", f"ghcr.io/dflow-sh/dflow-server:{version}")
must_contain(".github/workflows/release.yml", "tag: v0.0.0-dev")
must_contain(".github/workflows/release.yml", 'needle.replace("tag: v0.0.0-dev", f"tag: {tag}")')
must_contain(
    ".goreleaser.yaml",
    "-X github.com/dflow-sh/kube-poc/packages/dflow/version.Version=v{{ .Version }}",
)
must_contain('.goreleaser.yaml', 'org.opencontainers.image.version: "v{{ .Version }}"')
must_contain("packages/dflow/pkg/api/core/v1/models/models.go", "DefaultBuilderImage = BuildModeRailpack")
must_contain(
    "packages/dflow/cli/server.go",
    'flags.String("default-builder-image", models.DefaultBuilderImage,',
)
must_contain("packages/dflow/cli/server.go", "version.ChartVersionFromEnv")
must_contain("packages/dflow/cli/cmd/version.go", "version.Version")
must_contain("packages/dflow/api/v1/info.go", "version.Version")
must_contain("packages/dflow/api/v1/info.go", "models.ResolveDefaultBuilderImage")
must_contain("packages/dflow/pkg/api/core/v1/client/http.go", "serverVersion == version.Version")
must_contain("packages/dflow/cli/server/server.go", "setSwaggerVersion(swaggerMap, version.Version)")

skip = {".git", "node_modules", "vendor", "dist", "chart-package"}
stale = "v1.14." + "3"
unpacker_tag = stale + "-rc1"
for path in root.rglob("*"):
    if not path.is_file() or any(part in skip for part in path.parts):
        continue
    if path.suffix not in {".go", ".yml", ".yaml", ".md", ".sh", ".json"}:
        continue
    text = path.read_text(errors="ignore").replace(unpacker_tag, "")
    if stale in text:
        errors.append(f"stale product version in {path.relative_to(root)}")

if errors:
    print("version check failed:", file=sys.stderr)
    for item in errors:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)

print(f"version check ok ({version}, default builder railpack)")
PY
