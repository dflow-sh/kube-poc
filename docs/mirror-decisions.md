# Mirror decisions

## CI scan and sign

Images are copied and pinned by manifest digest. This change does not vulnerability-scan them and does not sign them. A scan or signature gate can be added once the mirror packages are public. Until then the digest pin is what a cluster pulls.

## Unpacker

The chart keeps the published unpacker image, copied into `ghcr.io/dflow-sh/mirror/unpacker` and pinned. This repository does not build a replacement.

## BuildKit

Railpack still runs the mirrored BuildKit image (`ghcr.io/dflow-sh/mirror/buildkit`, pinned). This change does not switch the stage runtime. A build still downloads the railpack CLI from GitHub. That download is outside `scripts/install.sh`.

## Dex

Dex stays enabled. The chart runs the published PKCE Dex image, copied into `ghcr.io/dflow-sh/mirror/dex` and pinned. This repository does not build Dex.
