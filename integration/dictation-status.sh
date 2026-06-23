#!/usr/bin/env bash
# Emits JSON state for the Wayle "dictation" custom module (consumed via icon-map + class-format).
#   recording -> a capture is in flight (dictation-rec unit active)
#   down      -> whisper-npu server not running
#   nomic     -> server up but no usable microphone (Bluetooth headset not connected)
#   idle      -> server up + mic available, ready to record
# Coloring: idle/nomic/down share the "fg-subtle" base icon-color (set in config.toml); only
# recording is tinted red in styles/index.scss. The mic vs mic-off glyph distinguishes ready
# from unavailable. Cheap (systemctl + one wpctl call) so it's safe to poll every second.
#
# Note: mic detection keys off a connected `[bluez5]` device, since on this hardware the
# internal mic is non-functional and the headset is the only capture source. Adjust the
# grep if you dictate from a wired/USB mic.
set -uo pipefail

if systemctl --user is-active --quiet dictation-rec; then
  printf '{"alt":"recording","tooltip":"Dictation: recording — click to stop"}'
elif ! systemctl --user is-active --quiet whisper-npu; then
  printf '{"alt":"down","tooltip":"Dictation server is DOWN — systemctl --user start whisper-npu"}'
elif command -v wpctl >/dev/null 2>&1 && ! wpctl status 2>/dev/null | grep -q '\[bluez5\]'; then
  printf '{"alt":"nomic","tooltip":"No microphone — connect your Bluetooth headset"}'
else
  printf '{"alt":"idle","tooltip":"Dictation ready — click or press the Assistant button to start"}'
fi
