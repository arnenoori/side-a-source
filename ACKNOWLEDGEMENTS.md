# Acknowledgements

Side A ships a build of tmux at `Side A.app/Contents/Helpers/tmux` so hosted sessions work without Homebrew. `scripts/build-tmux.sh` builds it from pinned sources, with these libraries linked in statically. Each license's full text ships in the app at `Contents/Resources/Licenses/`.

| Software | Version | License |
| --- | --- | --- |
| [tmux](https://github.com/tmux/tmux) | 3.7c | ISC |
| [libevent](https://libevent.org) | 2.1.13 | BSD 3-Clause |
| [ncurses](https://invisible-island.net/ncurses/) | 6.6 | MIT (X11) |
| [utf8proc](https://github.com/JuliaStrings/utf8proc) | 2.12.0 | MIT |
| [jemalloc](https://github.com/jemalloc/jemalloc) | 5.4.0 | BSD 2-Clause |

The `tmux-256color` terminal description in `Contents/Resources/terminfo` is compiled from ncurses' `misc/terminfo.src`.

[Sparkle](https://sparkle-project.org) 2.9.6 (MIT) provides automatic updates.

The iPhone app (Side A Remote) draws its terminal with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.11.2 (MIT).
