#!/usr/bin/env sh
# install.sh - install/uninstall msi-power-profile. Pure POSIX sh, no make.
#
# System-scope: the profile applier writes sysfs, the monitor runs as a
# system service, the udev rule lives in /etc/, and the tray ships its user
# service in /etc/systemd/user/ so any logged-in user can enable it.
#
# Defaults:
#   - apt-installs required runtime dependencies on Debian/Ubuntu/Kali
#   - on XFCE, rewrites existing genmon panel entries that point at the old
#     .sh paths to the new extensionless install paths (so panel widgets
#     keep working after a fresh install over a previous version)
#
# Usage:
#   ./install.sh              # install (default)
#   ./install.sh --no-deps    # skip apt-get; do not install dependencies
#   ./install.sh --no-xfconf  # skip XFCE panel/keyboard rewrites
#   ./install.sh --uninstall  # uninstall

set -eu

cd "$(dirname "$0")"

action=install
do_deps=1
do_xfconf=1

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) action=uninstall ;;
        --no-deps)   do_deps=0 ;;
        --no-xfconf) do_xfconf=0 ;;
        -h|--help)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

PREFIX=/usr/local
SYSTEMD_SYS=/etc/systemd/system
SYSTEMD_USER=/etc/systemd/user
UDEV_RULES=/etc/udev/rules.d
ICONS_DIR=/usr/share/icons/hicolor/scalable/status
XDG_AUTOSTART=/etc/xdg/autostart

# ---------- upstream credit ----------
banner() {
    cat <<'BANNER'
msi-power-profile - userspace power profile suite (Apache-2.0)
Built on top of msi-ec by BeardOverflow:
    https://github.com/BeardOverflow/msi-ec  (GPL-2.0 kernel module)
This installer deploys the userspace bits only. msi-ec must be installed
separately for /sys/devices/platform/msi-ec/ to be exposed.

BANNER
}

# ---------- runtime sanity check ----------
check_msi_ec() {
    if [ ! -d /sys/devices/platform/msi-ec ]; then
        echo
        echo "WARNING: /sys/devices/platform/msi-ec/ is not present on this system."
        echo "  The profile applier requires the msi-ec kernel module to be loaded."
        echo "  Install it from: https://github.com/BeardOverflow/msi-ec"
        echo "  Until then, this suite will install but EC-level profile changes"
        echo "  (shift_mode, fan_mode) will silently no-op."
        echo
    fi
}

# ---------- apt dependencies ----------
install_deps() {
    [ "$do_deps" -eq 1 ] || return 0
    command -v apt-get >/dev/null || return 0

    echo "Installing runtime dependencies via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        libnotify-bin \
        python3-gi \
        gir1.2-ayatanaappindicator3-0.1
    # Note: xfce4-panel >= 4.16 has StatusNotifier support built in, so no
    # separate plugin is needed on modern XFCE. On older XFCE (4.12 and
    # earlier) install xfce4-statusnotifier-plugin manually from your distro.
}

# ---------- XFCE panel + keyboard rewrites ----------
# When a previous version of this suite was installed with .sh paths, the
# user's existing panel/genmon entries and keyboard shortcuts point at
# binaries we no longer ship. Rewrite them in place rather than asking the
# user to right-click each entry. Idempotent.
rewrite_xfconf() {
    [ "$do_xfconf" -eq 1 ] || return 0
    command -v xfconf-query >/dev/null || return 0

    # Map old -> new for the three commands users might have bound.
    rewrite_panel
    rewrite_keyboard
    if pgrep -x xfce4-panel >/dev/null 2>&1; then
        xfce4-panel --restart >/dev/null 2>&1 || true
    fi
}

rewrite_panel() {
    xfconf-query -c xfce4-panel -l 2>/dev/null \
        | grep -E '/plugins/plugin-[0-9]+/command$' \
        | while read -r prop; do
            cmd=$(xfconf-query -c xfce4-panel -p "$prop" 2>/dev/null || true)
            new=$(map_old_to_new "$cmd")
            if [ -n "$new" ] && [ "$cmd" != "$new" ]; then
                echo "  xfce4-panel: $prop"
                echo "    $cmd"
                echo "    -> $new"
                xfconf-query -c xfce4-panel -p "$prop" -s "$new"
            fi
        done
}

rewrite_keyboard() {
    xfconf-query -c xfce4-keyboard-shortcuts -l 2>/dev/null \
        | grep -E '^/commands/custom/' \
        | while read -r prop; do
            cmd=$(xfconf-query -c xfce4-keyboard-shortcuts -p "$prop" 2>/dev/null || true)
            new=$(map_old_to_new "$cmd")
            if [ -n "$new" ] && [ "$cmd" != "$new" ]; then
                echo "  xfce4-keyboard-shortcuts: $prop"
                echo "    $cmd"
                echo "    -> $new"
                xfconf-query -c xfce4-keyboard-shortcuts -p "$prop" -s "$new"
            fi
        done
}

map_old_to_new() {
    case "$1" in
        */tlp-genmon.sh)             echo "$PREFIX/bin/tlp-genmon"             ;;
        */power-profile-request.sh)  echo "$PREFIX/bin/power-profile-request"  ;;
        # power-profile-genmon.sh is no longer shipped (the AppIndicator
        # tray replaces it). Panel entries pointing at the old .sh path are
        # left untouched so they break visibly - users should remove the
        # entry from their panel and rely on the tray.
        *) echo "" ;;
    esac
}

# ---------- reload the invoking user's systemd manager ----------
# install.sh runs as root, but the tray is a *user* unit. After (re)installing
# it, the user's systemd manager still has the old view, so the user's next
# `systemctl --user` command warns "unit file changed on disk". Reload it for
# the invoking user (best-effort; harmless if there is no user session).
user_daemon_reload() {
    [ -n "${SUDO_USER:-}" ] || return 0
    _uid=$(id -u "$SUDO_USER") || return 0
    sudo -u "$SUDO_USER" env XDG_RUNTIME_DIR="/run/user/$_uid" \
        systemctl --user daemon-reload 2>/dev/null || true
}

# ---------- main ----------

if [ "$action" = "install" ]; then
    banner
    check_msi_ec
    install_deps

    sudo install -d "$PREFIX/bin" "$SYSTEMD_SYS" "$SYSTEMD_USER" "$UDEV_RULES" "$XDG_AUTOSTART"

    sudo install -m 0755 src/power-profile.sh         "$PREFIX/bin/power-profile"
    sudo install -m 0755 src/power-profile-monitor.sh "$PREFIX/bin/power-profile-monitor"
    sudo install -m 0755 src/power-profile-request.sh "$PREFIX/bin/power-profile-request"
    sudo install -m 0755 src/power-source-hook.sh     "$PREFIX/bin/power-source-hook"
    sudo install -m 0755 tray/power-profile-tray.py   "$PREFIX/bin/power-profile-tray"

    # XFCE-specific extras: tlp-genmon shows a richer status readout (CPU
    # governor / EPP / turbo / freq / EC / battery) than the AppIndicator
    # label can carry. Optional; harmless on other DEs.
    sudo install -m 0755 xfce/tlp-genmon.sh "$PREFIX/bin/tlp-genmon"

    # XFCE login integration. XFCE does not activate graphical-session.target,
    # so the tray's user unit (WantedBy=graphical-session.target) is never
    # pulled in on login the way it is under GNOME/KDE. This autostart entry
    # (OnlyShowIn=XFCE, inert elsewhere) runs inside the established session,
    # refreshes the user manager's DISPLAY/XAUTHORITY, and (re)starts the tray.
    sudo install -m 0755 xfce/power-profile-tray-autostart.sh \
        "$PREFIX/bin/power-profile-tray-autostart"
    sudo install -m 0644 xfce/power-profile-tray-autostart.desktop \
        "$XDG_AUTOSTART/power-profile-tray-autostart.desktop"

    # Custom tray icons (one per profile). Installed into the hicolor theme
    # under scalable/status so the AppIndicator finds them by name regardless
    # of the user's preferred icon theme.
    sudo install -d "$ICONS_DIR"
    sudo install -m 0644 icons/scalable/status/msi-power-ultra.svg          "$ICONS_DIR/"
    sudo install -m 0644 icons/scalable/status/msi-power-performance.svg    "$ICONS_DIR/"
    sudo install -m 0644 icons/scalable/status/msi-power-balanced.svg       "$ICONS_DIR/"
    sudo install -m 0644 icons/scalable/status/msi-power-eco.svg            "$ICONS_DIR/"
    sudo install -m 0644 icons/scalable/status/msi-power-source-ac.svg      "$ICONS_DIR/"
    sudo install -m 0644 icons/scalable/status/msi-power-source-battery.svg "$ICONS_DIR/"
    sudo gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

    sudo install -m 0644 systemd/system/power-profile-monitor.service "$SYSTEMD_SYS/"
    sudo install -m 0644 systemd/user/power-profile-tray.service     "$SYSTEMD_USER/"
    sudo install -m 0644 udev/99-power-source-hook.rules             "$UDEV_RULES/"

    # Tunable config: install the default ONLY if no /etc/msi-power-profile.conf
    # exists yet. Never clobber a user-edited config on reinstall. Always also
    # ship a .dist copy so users can diff against new defaults.
    sudo install -m 0644 config/msi-power-profile.conf /etc/msi-power-profile.conf.dist
    if [ ! -e /etc/msi-power-profile.conf ]; then
        sudo install -m 0644 config/msi-power-profile.conf /etc/msi-power-profile.conf
        echo "Installed default config at /etc/msi-power-profile.conf"
    else
        echo "Preserved existing /etc/msi-power-profile.conf (new defaults are in"
        echo "  /etc/msi-power-profile.conf.dist - diff to see what changed)"
    fi

    sudo systemctl daemon-reload
    user_daemon_reload
    sudo udevadm control --reload

    rewrite_xfconf

    echo
    echo "Installed. To enable:"
    echo "  sudo systemctl enable --now power-profile-monitor.service"
    echo "  systemctl --user enable --now power-profile-tray.service"
    echo
    echo "On XFCE the tray also auto-starts on login (and restarts on relogin)"
    echo "via /etc/xdg/autostart: XFCE does not activate graphical-session.target"
    echo "the way GNOME/KDE do, so the user unit needs that nudge to come up."
    echo
    echo "Optional keyboard shortcut: bind Super+F12 (or similar) in your DE"
    echo "settings to: $PREFIX/bin/power-profile-request"
    echo
    echo "Note: this version drops the power-profile-genmon XFCE widget."
    echo "If you had it in your panel, remove the entry (right-click -> Remove)"
    echo "and rely on the tray indicator instead."
else
    sudo systemctl disable --now power-profile-monitor.service 2>/dev/null || true
    # Per-user tray instances are not auto-disabled - users do that themselves.

    sudo rm -f \
        "$PREFIX/bin/power-profile" \
        "$PREFIX/bin/power-profile-monitor" \
        "$PREFIX/bin/power-profile-request" \
        "$PREFIX/bin/power-source-hook" \
        "$PREFIX/bin/power-profile-tray" \
        "$PREFIX/bin/power-profile-genmon" \
        "$PREFIX/bin/tlp-genmon" \
        "$PREFIX/bin/power-profile-tray-autostart" \
        "$SYSTEMD_SYS/power-profile-monitor.service" \
        "$SYSTEMD_USER/power-profile-tray.service" \
        "$XDG_AUTOSTART/power-profile-tray-autostart.desktop" \
        "$UDEV_RULES/99-power-source-hook.rules" \
        "$ICONS_DIR/msi-power-ultra.svg" \
        "$ICONS_DIR/msi-power-performance.svg" \
        "$ICONS_DIR/msi-power-balanced.svg" \
        "$ICONS_DIR/msi-power-eco.svg" \
        "$ICONS_DIR/msi-power-source-ac.svg" \
        "$ICONS_DIR/msi-power-source-battery.svg" \
        /etc/msi-power-profile.conf.dist
    sudo gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

    # Never remove /etc/msi-power-profile.conf - it may contain user-tuned
    # values they want to keep for a reinstall.

    sudo systemctl daemon-reload
    user_daemon_reload
    sudo udevadm control --reload
    echo "Uninstalled."
    echo "  /etc/msi-power-profile.conf preserved (delete it manually if desired)."
    echo "  XFCE panel and keyboard bindings left intact."
fi
