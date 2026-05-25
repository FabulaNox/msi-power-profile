# msi-power-profile

Linux power-profile suite for the MSI Thin 15 B12UCX (and similar MSI laptops
with the `msi-ec` kernel module). Four named profiles - Ultra, Performance,
Balanced, Eco - layered on top of TLP. Automatic switching on AC transitions,
low battery, and thermal pressure. Cross-desktop status tray.

| profile | EC shift | fan | PL1 | PL2 | turbo | backlight |
|---|---|---|---|---|---|---|
| <img src="icons/scalable/status/msi-power-ultra.svg" width="20" alt="Ultra icon"> **ultra** | turbo | advanced | 35 W | 64 W | forced on | unchanged |
| <img src="icons/scalable/status/msi-power-performance.svg" width="20" alt="Performance icon"> **performance** | comfort | auto | 28 W | 55 W | TLP default | unchanged |
| <img src="icons/scalable/status/msi-power-balanced.svg" width="20" alt="Balanced icon"> **balanced** | eco | auto | 20 W | 40 W | TLP default | unchanged |
| <img src="icons/scalable/status/msi-power-eco.svg" width="20" alt="Eco icon"> **eco** | eco | silent | 15 W | 30 W | TLP default | 25% |

## Acknowledgments

This project is a strictly downstream userspace consumer of the
**[msi-ec](https://github.com/BeardOverflow/msi-ec)** kernel module by
[BeardOverflow](https://github.com/BeardOverflow). msi-ec exposes the MSI
laptop embedded controller (shift mode, fan mode, temperatures, etc) at
`/sys/devices/platform/msi-ec/`, which is what this suite reads and writes.

No msi-ec source is vendored or modified here, and the two projects sit at
different layers (kernel C vs userspace bash/python). If this is useful to
you, star upstream first - none of this works without their kernel module.

> **You must install msi-ec separately** before this suite is functional.
> See the upstream README for install instructions on your distro.

## Related projects

[MControlCenter](https://github.com/dmitry-s93/MControlCenter) is a Qt/C++
GUI control panel for MSI laptops, also built on top of msi-ec. It is
substantially more comprehensive than this suite (full graphical control
surface) and is the right choice if you want a desktop application.

msi-power-profile is positioned differently: CLI-first with a systemd
daemon and a minimal cross-DE tray, focused on automatic profile switching
driven by AC/battery/thermal events, with no GUI control center to open.
Pick whichever matches your workflow - or run both, they don't conflict
(both ultimately just write to the same msi-ec sysfs interface).

## Target hardware

Validated on the MSI Thin 15 B12UCX (Intel i5-12450H + intel_backlight,
`MAX_BRIGHTNESS=96000`). Should work on any MSI laptop where the msi-ec DKMS
module loads and exposes `/sys/devices/platform/msi-ec/`.

The CPU power management (RAPL + intel_pstate) is generic Intel and works on
any Intel laptop; the MSI-specific bits are EC shift mode and fan mode.

## Components

| File | Role | Install path |
|---|---|---|
| `src/power-profile.sh` | Apply a named profile (sysfs writer) | `/usr/local/bin/power-profile` |
| `src/power-profile-monitor.sh` | Daemon: AC/battery/thermal watchdog | `/usr/local/bin/power-profile-monitor` |
| `src/power-profile-request.sh` | Unprivileged: drop a request for the monitor | `/usr/local/bin/power-profile-request` |
| `src/power-source-hook.sh` | udev hook: desktop notification on AC change | `/usr/local/bin/power-source-hook` |
| `tray/power-profile-tray.py` | Cross-DE status tray (AppIndicator) with distinct icon + short label per profile | `/usr/local/bin/power-profile-tray` |
| `xfce/tlp-genmon.sh` | Optional XFCE genmon widget: rich CPU/battery/EPP/turbo/EC status readout | `/usr/local/bin/tlp-genmon` |
| `xfce/power-profile-tray-autostart.{sh,desktop}` | XFCE login autostart for the tray (XFCE does not activate `graphical-session.target`) | `/usr/local/bin/power-profile-tray-autostart` + `/etc/xdg/autostart/` |
| `icons/scalable/status/msi-power-*.svg` | Custom status icons for the tray (one per profile) | `/usr/share/icons/hicolor/scalable/status/` |
| `config/msi-power-profile.conf` | Tunable defaults (TDP / thresholds / brightness) | `/etc/msi-power-profile.conf` |
| `systemd/system/power-profile-monitor.service` | System service for the daemon | `/etc/systemd/system/` |
| `systemd/user/power-profile-tray.service` | User service for the tray | `/etc/systemd/user/` |
| `udev/99-power-source-hook.rules` | udev rule firing on ADP1 change | `/etc/udev/rules.d/` |

The AppIndicator tray is the primary panel UX. `tlp-genmon` is an optional
XFCE-specific addition for users who want a richer status readout (it shows
CPU governor / EPP / turbo state / frequency / EC mode alongside battery) -
it polls passively and never duplicates the profile selector.

## Install

```sh
./install.sh
sudo systemctl enable --now power-profile-monitor.service
systemctl --user enable --now power-profile-tray.service
```

The install script is pure POSIX `sh` - no `make`, no build tools.

### Dependencies

| Package (Debian/Ubuntu/Kali) | Required for |
|---|---|
| `bash` | Shell scripts |
| `tlp` | Underlying CPU/battery management |
| `msi-ec` DKMS (BeardOverflow) | EC shift mode and fan mode |
| `libnotify-bin` (`notify-send`) | Desktop notifications |
| `python3` + `python3-gi` | Tray indicator |
| `gir1.2-ayatanaappindicator3-0.1` | Tray indicator (preferred) |
| `gir1.2-appindicator3-0.1` | Tray indicator (legacy fallback) |

### Desktop environment integration

The core (CLI + daemon + notifications) works everywhere. The tray needs the
right tray-rendering support per DE:

- **XFCE:** install `xfce4-statusnotifier-plugin` and add it to the panel.
- **GNOME:** install `gnome-shell-extension-appindicator` and enable it.
- **KDE Plasma:** native (no extra package needed).
- **Cinnamon, MATE, Budgie:** native or via their applet manager.

The tray works on both X11 and Wayland sessions.

#### XFCE: starting on login

The tray is a systemd *user* service wired to `graphical-session.target`. GNOME
and KDE activate that target when their session starts, so the unit comes up on
login - and is restarted on relogin - automatically. **XFCE does not activate
`graphical-session.target`**, so there the unit is never pulled in at login; and
after a logout/login the user manager's `DISPLAY`/`XAUTHORITY` can be stale, so a
plain `Restart=` ends up racing the X server and aborting before it can draw.

`install.sh` handles this by also installing an XFCE autostart entry
(`/etc/xdg/autostart/power-profile-tray-autostart.desktop`, `OnlyShowIn=XFCE`)
that runs *inside* the established session: it refreshes the X environment and
(re)starts the tray under systemd on every login. Nothing to do by hand, and it
is inert on other desktops.

### Uninstall

```sh
./install.sh --uninstall
```

## Configuration

All runtime tunables live in `/etc/msi-power-profile.conf` - a shell
`KEY=VALUE` file sourced by `power-profile` and `power-profile-monitor`.
The scripts ship with fallback defaults baked in (tuned for the MSI Thin
15 B12UCX), so a missing or partial config still works - the file is for
overrides.

```sh
sudo $EDITOR /etc/msi-power-profile.conf
sudo systemctl restart power-profile-monitor.service
```

`install.sh` deploys the default to `/etc/msi-power-profile.conf` **only
if that file does not already exist**, so a reinstall never clobbers your
tuning. The latest packaged defaults are always written to
`/etc/msi-power-profile.conf.dist` so you can diff after upgrades.

### Knobs

| Variable | Default | Purpose |
|---|---|---|
| `ULTRA_PL1` / `ULTRA_PL2` | 35 / 64 W | RAPL sustained / burst for Ultra |
| `PERFORMANCE_PL1` / `PERFORMANCE_PL2` | 28 / 55 W | RAPL for Performance |
| `BALANCED_PL1` / `BALANCED_PL2` | 20 / 40 W | RAPL for Balanced |
| `ECO_PL1` / `ECO_PL2` | 15 / 30 W | RAPL for Eco |
| `MAX_BRIGHTNESS` | 96000 | Raw `intel_backlight` max (HARDWARE-SPECIFIC) |
| `ECO_BRIGHTNESS_PCT` | 25 | Eco-mode backlight as % of max |
| `LOW_BAT_THRESHOLD` | 15 | Battery % below which auto-switch to Eco |
| `PERFORMANCE_BAT_THRESHOLD` | 60 | On AC-unplug at/above -> Performance, below -> Balanced |
| `THERMAL_TRIP` | 85 | CPU C above which Ultra thermal counter increments |
| `THERMAL_READINGS` | 3 | Consecutive trips required to drop Ultra -> Performance |

Find your `MAX_BRIGHTNESS`:

```sh
cat /sys/class/backlight/intel_backlight/max_brightness
```

### Trigger matrix (the monitor daemon)

| Event | Condition | Profile |
|---|---|---|
| Boot | battery >= 15% | performance |
| Boot | battery < 15% | eco |
| AC plugged in | any | ultra |
| AC unplugged | battery >= 60% | performance |
| AC unplugged | 15% <= battery < 60% | balanced |
| Low battery | bat < 15%, not in eco, no override | eco |
| Thermal | CPU >= 85 C for 3 readings (~30 s) | drop ultra to performance |
| Manual request | request file written | as requested |

### State files (all in `/run/power-profile/`, cleared on reboot)

| File | Purpose |
|---|---|
| `state` | Current profile name, 644 readable by all |
| `prev-brightness` | Saved backlight before eco dimming |
| `low-bat-override` | User manually escaped eco lock this session |
| `request` | IPC: tray or request helper drops a profile name or `next` |

## Manual usage

```sh
sudo power-profile ultra
sudo power-profile performance
sudo power-profile balanced
sudo power-profile eco
sudo power-profile next          # cycle: ultra -> perf -> bal -> ultra
sudo power-profile next --force  # cycle even if locked in eco
```

Unprivileged users cycle the profile by writing `/run/power-profile/request`
(the directory is sticky world-writable, mirroring `/tmp` semantics). The
helper:

```sh
power-profile-request   # drops "next" into the request file
```

is bound to a keyboard shortcut for daily use (configure in your DE's keyboard
settings, e.g. `Super+F12`).

## Logs / debugging

```sh
journalctl -t power-profile -n 20 --no-pager
journalctl -t power-profile-monitor -n 20 --no-pager
journalctl -t power-profile-request -n 20 --no-pager
journalctl -t power-hook -n 20 --no-pager
systemctl status power-profile-monitor
systemctl --user status power-profile-tray
cat /run/power-profile/state
```

If the tray shows nothing on GNOME: confirm the AppIndicator extension is
installed AND enabled (`gnome-extensions list`). GNOME does not natively
render tray icons.

If the tray shows nothing on XFCE: confirm `xfce4-statusnotifier-plugin` is
in the panel (right-click panel -> Add New Items), and that the user service is
running (`systemctl --user status power-profile-tray`). After a relogin it is
brought back up by `/etc/xdg/autostart/power-profile-tray-autostart.desktop`; if
it is dead, `systemctl --user reset-failed power-profile-tray` then re-run that
autostart helper (or just log out and back in).

## License

Apache 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE).
