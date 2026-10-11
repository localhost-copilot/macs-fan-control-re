"""Finder layout, written directly so CI does not need Finder automation."""
import os

application = os.path.abspath("dist/Macs Fan Control.app")
files = [application]
symlinks = {"Applications": "/Applications"}
badge_icon = os.path.join(application, "Contents", "Resources", "FanControl.icns")
format = "UDZO"
background = defines["background"]
window_rect = ((200, 200), (640, 400))
icon_locations = {"Macs Fan Control.app": (180, 205), "Applications": (460, 205)}
icon_size = 96
text_size = 14
default_view = "icon-view"
show_icon_preview = False
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
