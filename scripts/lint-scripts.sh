#!/usr/bin/env bash
# Lints the workflows and every shell script in the repository: actionlint, and shellcheck over scripts/, .githooks/, the daemon's packaging and the site's install.sh.
# A missing tool fails, so a gate can't pass by skipping the check. check.sh and local-ci.sh both call this.
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in actionlint shellcheck; do
  command -v "$tool" >/dev/null || { echo "lint-scripts.sh: $tool is not installed, so this change can't be checked. Install it with: brew install $tool" >&2; exit 1; }
done
actionlint
shellcheck scripts/*.sh .githooks/* Daemon/Packaging/*.sh
shellcheck -s sh site/public/install.sh
