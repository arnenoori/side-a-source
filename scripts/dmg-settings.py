"""dmgbuild settings; layout is written directly without automating Finder."""
from pathlib import Path

# build-dmg.sh enters the repository root; dmgbuild executes settings without __file__.
root = Path.cwd()
application = str(root / "dist/universal/Side A.app")
files = [application]
symlinks = {"Applications": "/Applications"}
icon = str(root / "design/SideA.icns")
background = str(root / "dist/installer-background.png")
format = "UDZO"
filesystem = "HFS+"
window_rect = ((100, 100), (680, 420))
icon_locations = {"Side A.app": (174, 210), "Applications": (506, 210)}
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
# Finder normally hides .app itself. Setting the extension-hidden flag explicitly
# adds com.apple.FinderInfo to the signed bundle and breaks strict verification.
hide_extensions = []
scroll_position = (0, 0)
