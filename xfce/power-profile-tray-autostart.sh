#!/usr/bin/env sh
# Start the tray on XFCE login.
#
# The tray ships as a systemd *user* service wired to graphical-session.target
# (WantedBy=/After=/PartOf=). GNOME and KDE activate that target when their
# session starts, so the unit is pulled in on login - and restarted on relogin -
# automatically. XFCE does NOT activate graphical-session.target, so on XFCE the
# unit is never started at login; and after a logout/login the user manager's
# DISPLAY/XAUTHORITY can be stale, which makes a plain Restart= race the X server
# and abort before it can draw.
#
# Run from an XFCE autostart entry, this helper executes inside the established
# session: it refreshes the user manager's X environment from the live session,
# then (re)starts the tray under systemd. It no-ops cleanly if the user has not
# enabled the tray.
set -eu

systemctl --user import-environment DISPLAY XAUTHORITY 2>/dev/null || exit 0
systemctl --user is-enabled power-profile-tray.service >/dev/null 2>&1 || exit 0
exec systemctl --user restart power-profile-tray.service
