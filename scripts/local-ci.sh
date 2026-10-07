#!/bin/bash
# All gates run on this Mac. Intel is cross-compiled; native tests use this host.
set -euo pipefail
cd "$(dirname "$0")/.."
actionlint
shellcheck scripts/*.sh
python3 -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s bridge/tests -v
cp bridge/*.py Sources/SideA/Resources/
swift test
npm --prefix site ci
npm --prefix site test
npm --prefix site run build
./scripts/build-app.sh release arm64
./scripts/build-app.sh release x86_64
./scripts/assemble-universal.sh
python3 -m venv .build/dmg-tools
.build/dmg-tools/bin/pip install -r scripts/requirements-dmg.txt
./scripts/build-dmg.sh
