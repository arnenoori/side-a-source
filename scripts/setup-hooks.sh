#!/usr/bin/env bash
# Points this clone at .githooks (the pre-push gate) when nothing else is configured. core.hooksPath lives in the
# clone's config, which every worktree of the clone shares, so one run covers them all. A fresh clone gets it the
# first time dev.sh or check.sh runs. A hooksPath someone chose on purpose is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d .githooks ]] || exit 0
if [[ -z "$(git config --get core.hooksPath || true)" ]]; then
  git config core.hooksPath .githooks
  echo "setup-hooks.sh: core.hooksPath is now .githooks, so pushes run scripts/check.sh."
fi
