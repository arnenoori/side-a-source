#!/usr/bin/env bash
# Removes what install.sh put in place. Paired phones and keys (~/.local/state/side-a) are kept unless --purge.
set -euo pipefail
prefix="${PREFIX:-$HOME/.local}"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
# `sidead hooks on` is the one thing outside the prefix that sidead adds (a marked hook in Claude Code's settings.json), so it
# goes first, while sidead and its bridge are still here to take it out.
if [[ -x "$prefix/bin/sidead" ]]; then
  "$prefix/bin/sidead" hooks off >/dev/null 2>&1 \
    || echo "uninstall.sh: couldn't run \`sidead hooks off\`; remove the hooks marked side-a-island from Claude Code's settings.json by hand." >&2
fi
if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user disable --now sidead.service 2>/dev/null || true
  rm -f "$config/systemd/user/sidead.service"
  systemctl --user daemon-reload || true
fi
rm -f "$prefix/bin/sidead"
rm -rf "$prefix/share/side-a/bridge"
rm -f "$prefix/share/side-a/uninstall.sh"
rmdir "$prefix/share/side-a" 2>/dev/null || true
rm -f "$config/side-a/sidead.env"
rmdir "$config/side-a" 2>/dev/null || true
if [[ "${1:-}" == --purge ]]; then rm -rf "${SIDEAD_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/side-a}"; fi
echo "sidead removed."
