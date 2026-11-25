# sidead 0.1.0

The Side A daemon for Linux, and for Windows through WSL 2 (a preview). Answer your Linux computer's Claude Code and Codex sessions from Side A Remote on your iPhone.

- Install: `curl -fsSL https://getsidea.com/install.sh | sh`, then `sidead pair`.
- Lists and reads running sessions, takes replies, starts sessions in tmux, and shows each Claude account's limits.
- Reaches the phone over Tailscale, the same network, or Side A's relay (on by default; `--no-relay` turns it off).
- Not yet: approving permission requests from the phone, questions and plans, Autopilot, photos, the terminal view.

x86-64 and arm64, glibc 2.39 or newer (Ubuntu 24.04, Debian 13, Fedora 40), tmux 3.4 or newer, Python 3.9 or newer. Packages: a tarball and a .deb for each architecture, with SHA-256 sums.
