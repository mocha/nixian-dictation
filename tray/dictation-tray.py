#!/usr/bin/env python3
"""dictation-tray — cross-desktop system-tray status + control for the dictation tool.

A StatusNotifierItem (via AppIndicator) hosted natively by both KDE's system tray (Dynamo) and
Wayle's tray (Nixian) — one status UI for both desktops, replacing the Wayle-specific bar module.
It shows dictation state as an icon (idle / recording / server-down) and offers a menu to toggle
dictation, dictate copy-only, restart the server, or quit. The push-to-talk keybind flow is
untouched — this sits alongside it.

State is derived by polling systemd --user units once a second (no new IPC): the recording unit
(dictation-rec) and the transcription server unit. Env:
  DICTATION_SERVER_UNIT  server unit to watch/restart (default dictation-whisper)
  DICTATION_REC_UNIT     recording unit (default dictation-rec)
  DICTATION_TOGGLE_CMD   toggle command / path (default dictation-toggle)
"""
import os
import subprocess

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib  # noqa: E402

# Prefer libayatana-appindicator; fall back to the older libappindicator namespace.
AppIndicator = None
for _ns in ("AyatanaAppIndicator3", "AppIndicator3"):
    try:
        gi.require_version(_ns, "0.1")
        AppIndicator = getattr(__import__("gi.repository", fromlist=[_ns]), _ns)
        break
    except (ValueError, ImportError):
        continue
if AppIndicator is None:
    raise SystemExit("dictation-tray: no AppIndicator typelib found (need libayatana-appindicator)")

SERVER_UNIT = os.environ.get("DICTATION_SERVER_UNIT", "dictation-whisper")
REC_UNIT = os.environ.get("DICTATION_REC_UNIT", "dictation-rec")
TOGGLE_CMD = os.environ.get("DICTATION_TOGGLE_CMD", "dictation-toggle")

# state -> (themed icon name, tooltip). Names are Breeze/freedesktop stock so the theme colours
# them (no bundled assets); "media-record" is the red dot everyone recognises as recording.
ICONS = {
    "recording": ("media-record", "Dictation: recording — toggle to stop"),
    "idle": ("audio-input-microphone", "Dictation: ready"),
    "down": ("audio-input-microphone-muted", f"Dictation server down ({SERVER_UNIT})"),
}


def _unit_active(unit):
    return subprocess.run(
        ["systemctl", "--user", "is-active", "--quiet", unit],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def _state():
    if _unit_active(REC_UNIT):
        return "recording"
    if not _unit_active(SERVER_UNIT):
        return "down"
    return "idle"


class Tray:
    def __init__(self):
        icon, tip = ICONS["idle"]
        self.ind = AppIndicator.Indicator.new(
            "dictation", icon, AppIndicator.IndicatorCategory.APPLICATION_STATUS
        )
        self.ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.ind.set_title("Dictation")
        self.ind.set_menu(self._menu())
        self.state = None
        self._refresh()
        GLib.timeout_add_seconds(1, self._refresh)

    def _menu(self):
        m = Gtk.Menu()

        def item(label, cb):
            it = Gtk.MenuItem(label=label)
            it.connect("activate", cb)
            m.append(it)
            return it

        self.toggle_item = item("Start dictation", self._toggle)
        item("Dictate (copy only)", self._toggle_copyonly)
        m.append(Gtk.SeparatorMenuItem())
        item("Restart server", self._restart_server)
        m.append(Gtk.SeparatorMenuItem())
        item("Quit tray", lambda _=None: Gtk.main_quit())
        m.show_all()
        # Middle-click the tray icon = toggle (left-click opens this menu on KDE/Wayle).
        self.ind.set_secondary_activate_target(self.toggle_item)
        return m

    def _refresh(self, *_):
        st = _state()
        if st != self.state:
            self.state = st
            icon, tip = ICONS[st]
            self.ind.set_icon_full(icon, tip)
            self.toggle_item.set_label("Stop dictation" if st == "recording" else "Start dictation")
        return True  # keep the GLib timer alive

    def _toggle(self, *_):
        subprocess.Popen([TOGGLE_CMD])

    def _toggle_copyonly(self, *_):
        subprocess.Popen([TOGGLE_CMD], env=dict(os.environ, DICTATION_NOPASTE="1"))

    def _restart_server(self, *_):
        subprocess.Popen(["systemctl", "--user", "restart", SERVER_UNIT])


def main():
    Tray()
    Gtk.main()


if __name__ == "__main__":
    main()
