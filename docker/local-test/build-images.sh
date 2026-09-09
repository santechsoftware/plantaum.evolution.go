#!/usr/bin/env bash
# Builds both images: the working tree (fixed) and BASE_COMMIT (baseline).
#
# The baseline is fed to docker as a tar stream straight out of git, so no
# worktree or temp checkout is needed and the working tree is never touched.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# Last commit before the pool fix — the upstream 0.7.2 sync.
BASE_COMMIT="${BASE_COMMIT:-9337afc}"

echo "==> fixed    <- working tree"
docker build -q -t evogo-localtest:fixed --build-arg VERSION=fixed-local "$ROOT"

echo "==> baseline <- $BASE_COMMIT ($(git -C "$ROOT" log -1 --format=%s "$BASE_COMMIT"))"
git -C "$ROOT" archive --format=tar "$BASE_COMMIT" \
  | docker build -q -t evogo-localtest:baseline --build-arg VERSION=baseline-local -

echo
docker images --filter=reference='evogo-localtest:*' \
  --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'
