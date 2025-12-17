#!/bin/bash
# Launch foot terminal with status bar in the reserved strut area
foot --title="niri-statusbar" \
     --app-id="niri-statusbar" \
     --window-size-chars=200x1 \
     -e python3 ~/.config/niri/urwid_niri_statusbar.py