#!/bin/bash
# The app reads its bridge from Sources/SideA/Resources; bridge/ is the source. Builds and tests copy it in first.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f Sources/SideA/Resources/*.py
cp bridge/*.py Sources/SideA/Resources/
