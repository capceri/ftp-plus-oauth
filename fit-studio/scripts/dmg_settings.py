# dmgbuild settings for the FIT Studio disk image. Used by scripts/make_dmg.sh:
#   dmgbuild -s scripts/dmg_settings.py -D app=... -D background=... -D icon=... "FIT Studio" out.dmg
# Icon positions match the arrow drawn by scripts/make_dmg_background.py.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = ((200, 140), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (160, 185),
    "Applications": (440, 185),
}
hide_extension = [app_name]
