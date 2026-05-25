#!/usr/bin/env python3
"""msi-power-profile tray indicator.

Cross-desktop status tray for the power-profile suite. Reads the state file
written by power-profile-monitor and dispatches profile changes through
/run/power-profile/request, which the monitor reads back and applies.

Works on XFCE, GNOME (with the AppIndicator extension), KDE Plasma, Cinnamon,
MATE, Budgie - any DE that supports the StatusNotifierItem spec.

Dependencies (Debian/Ubuntu):
    python3-gi
    gir1.2-ayatanaappindicator3-0.1   (preferred, actively maintained)
        OR
    gir1.2-appindicator3-0.1          (legacy fallback)

On GNOME you also need `gnome-shell-extension-appindicator` installed and
enabled - GNOME does not natively render tray icons.
"""

import os
import sys

import gi

gi.require_version("Gtk", "3.0")

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
except (ImportError, ValueError):
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3

from gi.repository import GLib, Gtk

STATE_FILE = "/run/power-profile/state"
REQUEST_FILE = "/run/power-profile/request"
BATTERY_FILE = "/sys/class/power_supply/BAT1/capacity"
LOW_BAT_OVERRIDE = "/run/power-profile/low-bat-override"
POLL_INTERVAL_SECONDS = 5

PROFILES = [
    ("ultra",       "Ultra"),
    ("performance", "Performance"),
    ("balanced",    "Balanced"),
    ("eco",         "Eco"),
]

# Distinctive custom icons shipped with the package. Installed to
# /usr/share/icons/hicolor/scalable/status/ and picked up by name through
# the freedesktop icon theme spec.
PROFILE_ICONS = {
    "ultra":       "msi-power-ultra",
    "performance": "msi-power-performance",
    "balanced":    "msi-power-balanced",
    "eco":         "msi-power-eco",
}

# Short panel labels (the AppIndicator renders this next to the icon).
PROFILE_LABELS = {
    "ultra":       "Ultra",
    "performance": "Perf",
    "balanced":    "Bal",
    "eco":         "Eco",
}


def read_text(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def request_profile(name):
    """Drop a profile name (or "next") into the monitor's request file."""
    try:
        with open(REQUEST_FILE, "w") as f:
            f.write(name)
    except OSError as e:
        print(f"power-profile-tray: failed to write request: {e}", file=sys.stderr)


class Tray:
    def __init__(self):
        self.indicator = AppIndicator3.Indicator.new(
            "power-profile-tray",
            "weather-clear",
            AppIndicator3.IndicatorCategory.HARDWARE,
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        self.menu = Gtk.Menu()
        self._build_menu()
        self.indicator.set_menu(self.menu)
        self.refresh()
        GLib.timeout_add_seconds(POLL_INTERVAL_SECONDS, self._tick)

    def _build_menu(self):
        for name, label in PROFILES:
            item = Gtk.MenuItem(label=label)
            item.connect("activate", lambda _w, n=name: request_profile(n))
            self.menu.append(item)

        self.menu.append(Gtk.SeparatorMenuItem())

        cycle = Gtk.MenuItem(label="Cycle profile")
        cycle.connect("activate", lambda _w: request_profile("next"))
        self.menu.append(cycle)

        self.menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit tray")
        quit_item.connect("activate", lambda _w: Gtk.main_quit())
        self.menu.append(quit_item)

        self.menu.show_all()

    def refresh(self):
        profile = read_text(STATE_FILE, "performance")
        battery = read_text(BATTERY_FILE, "?")
        override = os.path.exists(LOW_BAT_OVERRIDE)

        icon = PROFILE_ICONS.get(profile, "dialog-question")
        self.indicator.set_icon_full(icon, f"Power profile: {profile}")

        label = PROFILE_LABELS.get(profile, "?")
        if profile == "eco" and override:
            label = "Eco*"
        # "Eco*" is the widest label this can produce - the guide hint keeps
        # the slot from re-flowing when the label string changes width.
        self.indicator.set_label(label, "Ultra")

        self.indicator.set_title(f"Power Profile: {label} (battery {battery}%)")
        return True

    def _tick(self):
        self.refresh()
        return True


def main():
    Tray()
    try:
        Gtk.main()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
