#!/bin/bash
# Use the same temporary signing boundary on a hosted or one-job local runner.
set -euo pipefail
cd "$(dirname "$0")/.."
for name in SIGNING_CERTIFICATE_BASE64 SIGNING_CERTIFICATE_PASSWORD NOTARY_PRIVATE_KEY SPARKLE_PRIVATE_KEY; do
  [[ -n "${!name:-}" ]] || { echo "Missing credential: $name" >&2; exit 1; }
done
umask 077
credential_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sidea-signing.XXXXXX")"
export SIGNING_KEYCHAIN="$credential_dir/signing.keychain-db"
export NOTARY_KEY_PATH="$credential_dir/AuthKey.p8"
export SPARKLE_PRIVATE_KEY_FILE="$credential_dir/sparkle.key"
original_keychains=()
cleanup() {
  if [[ ${#original_keychains[@]} -gt 0 ]]; then security list-keychains -d user -s "${original_keychains[@]}" || true; fi
  security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$credential_dir"
}
trap cleanup EXIT
export SIDEA_CREDENTIAL_DIR="$credential_dir"
python3 - <<'PY'
import base64, os, pathlib
directory = pathlib.Path(os.environ['SIDEA_CREDENTIAL_DIR'])
(directory / 'certificate.p12').write_bytes(base64.b64decode(os.environ['SIGNING_CERTIFICATE_BASE64'], validate=True))
(directory / 'AuthKey.p8').write_text(os.environ['NOTARY_PRIVATE_KEY'])
(directory / 'sparkle.key').write_text(os.environ['SPARKLE_PRIVATE_KEY'])
PY
keychain_password="$(openssl rand -hex 32)"
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::add-mask::$keychain_password"; fi
security create-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 3600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$SIGNING_KEYCHAIN"
security import "$credential_dir/certificate.p12" -P "$SIGNING_CERTIFICATE_PASSWORD" -k "$SIGNING_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$SIGNING_KEYCHAIN" >/dev/null
# codesign resolves the identity through the search list; a clean hosted Mac only finds it there.
while IFS= read -r line; do line="${line#*\"}"; original_keychains+=("${line%\"}"); done < <(security list-keychains -d user)
security list-keychains -d user -s "$SIGNING_KEYCHAIN" "${original_keychains[@]}"
security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | grep -qF "$SIGNING_IDENTITY" || { echo "Signing identity not found in the imported certificate" >&2; exit 1; }
rm "$credential_dir/certificate.p12"
./scripts/notarize-app.sh
swift package resolve
./scripts/build-appcast.sh
