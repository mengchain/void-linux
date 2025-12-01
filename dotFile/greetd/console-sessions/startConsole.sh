#!/bin/sh
# Console session startup script

# Source profile for environment setup
[ -f /etc/profile ] && . /etc/profile
[ -f "$HOME/.profile" ] && . "$HOME/.profile"

# Start user's login shell
# -l flag starts shell as login shell (POSIX compatible)
# Uses $SHELL from user's passwd entry, falls back to /bin/sh
exec "${SHELL:-/bin/sh}" -l
