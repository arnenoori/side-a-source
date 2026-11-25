# Side A on Windows

**Preview. No Windows machine has run any of this.** The site says so too (getsidea.com/windows). Everything here is the Linux daemon ([linux.md](linux.md)) run inside WSL 2,
written from Microsoft's and Tailscale's documentation. The Linux side of it is tested (Docker, arm64 and amd64);
the Windows parts (WSL setup, networking, starting at login) are unproven and are marked below. What the Linux side has now
run on real hardware (a Synology NAS: the install, a systemd user service, pairing over a real network, a relay) is in
[linux.md](linux.md#a-real-machine-a-synology-nas); WSL 2 adds its own distribution, kernel (a Microsoft 5.15 or 6.x one,
newer than the NAS's 4.4) and networking, and none of that was run. There is no native
Windows build, no tray and no Windows CI job: the only thing a Windows runner could run today is this document's steps,
which needs a WSL distribution, and hosted runners do not have a dependable one. The plan for a native port
(ConPTY instead of tmux, DPAPI for secrets, named pipes) stays in [the PRD](windows-linux-prd.md) and has not been started.

## What you get

The same `sidead` as on Linux, running in an Ubuntu distribution on WSL 2, controlled from the iPhone. It sees only what
runs **inside that distribution**: Claude Code and Codex installed in WSL, their `~/.claude` and `~/.codex` in the WSL
home, projects in the WSL filesystem. It does not see Claude Code for Windows (`C:\Users\you\.claude`), and cannot start
Windows programs. Projects under `/mnt/c` work but are slow (file access crosses to Windows); keep working copies in
`~` inside WSL.

## Install

1. Windows 11 or Windows 10 22H2 with WSL 2. In PowerShell: `wsl --install -d Ubuntu-24.04` and restart. Ubuntu 24.04 has
   the tmux 3.4 that hosting needs. *(Unproven here.)*
2. Turn on systemd for the distribution, once. In the Ubuntu shell:
   ```
   printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf
   ```
   then `wsl --shutdown` in PowerShell and open Ubuntu again.
3. Install the daemon inside Ubuntu, as in [linux.md](linux.md): `curl -fsSL https://getsidea.com/install.sh | sh` (it picks
   `amd64` or, on a Windows-on-Arm PC, `arm64`; the tarballs and `.deb` are on the same page). Install Claude Code or Codex
   in WSL the usual way and sign in there. `sudo apt install tmux python3` first if `install.sh` warns.
4. `sidead pair` and scan the code with Side A Remote.

## Reaching it from the phone

WSL 2 is a virtual machine on its own address, so the phone cannot see it by default. Pick one:

| Way | How | Notes |
| --- | --- | --- |
| **A relay** (simplest, and the default) | Nothing to do: `sidead` uses Side A's relay unless `SIDEAD_ARGS` has `--no-relay` | Only outbound connections: no Windows firewall or port changes, works on any network. Proven on Linux (a container and a NAS) against the relay's own code run locally, not against the deployed relay and not through WSL. |
| **Tailscale inside WSL** | Install Tailscale in the Ubuntu distribution (`curl -fsSL https://tailscale.com/install.sh \| sh`, `sudo tailscale up`) | The distribution gets its own tailnet address, which `sidead` finds by itself, so no port forwarding is needed. A Tailscale for Windows install does not do this for the distribution. *(Unproven here.)* |
| **The local network** | Use WSL's mirrored networking (Windows 11 22H2 or newer): in `%UserProfile%\.wslconfig` put `[wsl2]` and `networkingMode=mirrored`, then run `sidead` with `--lan`; allow inbound port 47800 in Windows Defender Firewall and for Hyper-V (`Set-NetFirewallHyperVVMSetting -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -DefaultInboundAction Allow`) | The phone and the PC must be on the same network. Without mirrored mode you would need a `netsh interface portproxy` rule that follows the distribution's changing address; that is not covered here (with one, `sidead` also needs `--allow-host` naming the Windows address, or it refuses the Host). *(Unproven here.)* |

## Keeping it running

WSL stops a distribution when nothing is using it, and a stopped `sidead` cannot answer the phone. Two things to know,
both unproven here:

- With systemd on, `sidead` runs as the same user service as on Linux (`systemctl --user status sidead`). Whether Windows
  keeps the distribution alive for a service with no open terminal depends on the WSL version; if the phone loses it a
  minute after you close the terminal, that is why.
- The dependable fix is a Windows scheduled task, At log on, that runs `wsl.exe -d Ubuntu-24.04 -- sleep infinity`, which
  keeps the distribution (and its user services) running. Put `sidead` in the task instead
  (`wsl.exe -d Ubuntu-24.04 -- sidead run`) if you do not use systemd.

Hosted sessions run in tmux inside the distribution, so they survive `sidead` restarting but not `wsl --shutdown` or a
Windows restart.

## What does not work

Everything [linux.md](linux.md) lists as not working, and: Windows-native agents, Windows notifications and tray, keeping the
PC awake (Windows may sleep and WSL with it), and any use of the Windows Credential Manager. Claude Code's logins in WSL
are files under the WSL home (`.credentials.json`), the same as on Linux, so accounts work as described there.

## What needs a Windows machine

All of it: that `wsl --install`, the systemd step and `install.sh` work as written; that `sidead pair` and a phone
connect over each of the three ways above; that the distribution stays up as described; and whether Windows Defender
Firewall asks anything on first run. If you run it, the quickest check is `sidead status` inside Ubuntu (it prints the
address the phone will use) and, on the phone, Settings, Computers.
