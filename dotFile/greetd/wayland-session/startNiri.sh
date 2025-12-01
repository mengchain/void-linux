#!/bin/bash
# Set Wayland-specific environment variables
export XDG_SESSION_TYPE=wayland
export WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}

# Add other Wayland-specific variables here if needed
export XDG_SESSION_DESKTOP=niri
export XDG_CURRENT_DESKTOP=niri

# For GTK apps: prefer Wayland,
GDK_BACKEND=wayland

# For OpenRC on Void Linux, use niri --session within dbus-run-session
exec niri --session
