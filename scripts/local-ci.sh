#!/bin/bash
# All gates run on this Mac. Intel is cross-compiled; native tests use this host.
set -euo pipefail
cd "$(dirname "$0")/.."
actionlint
shellcheck scripts/*.sh
python3 -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s bridge/tests -v
# The app accepts Python 3.9, which is macOS's own /usr/bin/python3.
if [[ "$(/usr/bin/python3 -c 'import sys; print(sys.version_info[:2] == (3, 9))' 2>/dev/null)" == True ]]; then
  /usr/bin/python3 -m unittest discover -s bridge/tests -v
fi
cp bridge/*.py Sources/SideA/Resources/
swift test
npm --prefix site ci
npm --prefix site test
npm --prefix site run build
SIDEA_RELEASE_BUILD=1 ./scripts/build-app.sh release arm64
SIDEA_RELEASE_BUILD=1 ./scripts/build-app.sh release x86_64
./scripts/assemble-universal.sh
# dmgbuild needs Python 3.10+; a Homebrew upgrade can leave python3 pointing at Apple's 3.9.
dmg_python=""
for candidate in python3.14 python3.13 python3.12 python3.11 python3.10; do
  if command -v "$candidate" >/dev/null; then dmg_python=$candidate; break; fi
done
[[ -n "$dmg_python" ]] || { echo "Python 3.10 or later is needed to build the disk image." >&2; exit 1; }
"$dmg_python" -m venv --clear .build/dmg-tools
.build/dmg-tools/bin/pip install -r scripts/requirements-dmg.txt
./scripts/build-dmg.sh
