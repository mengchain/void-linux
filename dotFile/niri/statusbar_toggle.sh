#!/bin/bash
PID_FILE="/tmp/niri-statusbar.pid"

# Check if already running
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if ps -p $PID > /dev/null 2>&1; then
        # Kill the existing instance
        kill $PID
        rm "$PID_FILE"
        exit 0
    fi
fi

# Start new instance
foot --title="niri-statusbar" \
     --app-id="niri-statusbar" \
     --window-size-chars=200x1 \
     -e python3 ~/.config/niri/urwid_niri_statusbar.py &

echo $! > "$PID_FILE"