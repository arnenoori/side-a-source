#!/usr/bin/env python3
"""dmgbuild, with a forced detach when a plain one is refused. A stuck CoreSimulatorService makes macOS
refuse every unmount ("Simulators are still shutting down"); dmgbuild has synced the volume by then."""
import sys

from dmgbuild import __main__ as cli
from dmgbuild import core

plain = core.hdiutil


def hdiutil(cmd, *args, **kwargs):
    result = plain(cmd, *args, **kwargs)
    if cmd == "detach" and result[0] and "-force" not in args:
        return plain(cmd, "-force", *args, **kwargs)
    return result


core.hdiutil = hdiutil
sys.exit(cli.main())
