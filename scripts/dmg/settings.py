"""Finder layout shared by the local preview and the signed release."""

format = "UDZO"
filesystem = "HFS+"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
# Do not set Finder flags on the app after signing; Finder already hides .app.
background = defines["background"]

window_rect = ((200, 200), (680, 460))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
grid_spacing = 80
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 16
icon_size = 128
icon_locations = {"tidest.app": (160, 220), "Applications": (520, 220)}
