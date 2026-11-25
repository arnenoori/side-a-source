#!/usr/bin/env bash
# Installs sidead for the current user from this folder; no root needed.
#   ./install.sh                 into ~/.local, with a systemd user service that starts now and at login
#   ./install.sh --no-service    the files only
#   PREFIX=/opt/side-a ./install.sh
# Uninstall with ~/.local/share/side-a/uninstall.sh (under the prefix, share/side-a). Nothing outside the prefix and ~/.config is touched.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
service=yes
[[ "${1:-}" == --no-service ]] && service=no

[[ "$(uname -s)" == Linux ]] || { echo "install.sh: this package is for Linux." >&2; exit 1; }
[[ -x "$here/bin/sidead" ]] || { echo "install.sh: run it from the unpacked folder." >&2; exit 1; }

missing="$(ldd "$here/bin/sidead" 2>/dev/null | sed -n 's/^[[:space:]]*\(.*\) => not found.*/\1/p' | tr '\n' ' ')"
if [[ -n "$missing" ]]; then
  echo "install.sh: sidead needs $missing, which this system doesn't have. On Ubuntu and Debian: sudo apt install libcurl4t64; on Fedora: sudo dnf install libcurl." >&2
  exit 1
fi
if ! command -v python3 >/dev/null; then
  echo "warning: python3 (3.9 or newer) isn't installed; sessions stay off until it is (sudo apt install python3)." >&2
fi
if command -v tmux >/dev/null; then
  have="$(tmux -V | sed -n 's/^tmux \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  major="${have% *}"; minor="${have#* }"
  if [[ -n "$have" ]] && (( major < 3 || (major == 3 && minor < 4) )); then
    echo "warning: $(tmux -V) is older than 3.4, which hosting needs. Ubuntu 24.04 and Debian 13 have it; on older systems build tmux 3.4 or newer." >&2
  fi
else
  echo "warning: tmux (3.4 or newer) isn't installed; hosted sessions need it (sudo apt install tmux)." >&2
fi

install -d "$prefix/bin" "$prefix/share/side-a"
install -m 755 "$here/bin/sidead" "$prefix/bin/sidead"
rm -rf "$prefix/share/side-a/bridge"
cp -R "$here/share/side-a/bridge" "$prefix/share/side-a/bridge"
install -m 755 "$here/uninstall.sh" "$prefix/share/side-a/uninstall.sh"
echo "Installed $("$prefix/bin/sidead" --version) in $prefix/bin"

config="${XDG_CONFIG_HOME:-$HOME/.config}"
install -d "$config/side-a"
if [[ ! -e "$config/side-a/sidead.env" ]]; then
  cat >"$config/side-a/sidead.env" <<'ENV'
# Options for the sidead service, one line. For example:
#   SIDEAD_ARGS=--lan                      also listen on this network (the phone must be on it)
#   SIDEAD_ARGS=--relay https://RELAY      reach this computer from anywhere through a Side A relay
#   SIDEAD_ARGS=--project /home/you/code   a folder the phone may start sessions in (repeat for more)
SIDEAD_ARGS=
ENV
fi

if [[ "$service" == yes ]]; then
  if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
    unit="$config/systemd/user"
    install -d "$unit"
    sed "s|@BIN@|$prefix/bin/sidead|" "$here/lib/systemd/user/sidead.service" >"$unit/sidead.service"
    systemctl --user daemon-reload
    systemctl --user enable sidead.service
    systemctl --user restart sidead.service
    echo "The sidead service is running. To keep it running when you are logged out: sudo loginctl enable-linger $USER"
  else
    echo "No systemd user session here, so no service was set up. Start it with: $prefix/bin/sidead run" >&2
  fi
fi

case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "Add $prefix/bin to your PATH to run sidead by name." ;; esac
echo
echo "Next: sidead pair   (shows a QR code for Side A Remote on your iPhone)"
exit 0
