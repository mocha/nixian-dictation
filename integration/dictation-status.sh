#!/usr/bin/env bash
# Emits JSON state for the Wayle "dictation" custom module (consumed via icon-map + class-format).
#   recording -> a capture is in flight (dictation-rec unit active)
#   down      -> whisper-npu server not running
#   nomic     -> server up but no usable microphone available
#   idle      -> server up + mic available, ready to record
# "Usable mic" mirrors what dictation-toggle.sh can actually record from: a Bluetooth headset
# (HFP path), or the default PipeWire source as long as it isn't one of the dead internal
# Panther Lake SoundWire/SOF mics (node.name …sof_sdw…, no working capture on this hardware).
# Coloring: idle/nomic/down share the "fg-subtle" base icon-color (set in config.toml); only
# recording is tinted red in styles/index.scss. The mic vs mic-off glyph distinguishes ready
# from unavailable. Cheap (systemctl + at most two wpctl calls) so it's safe to poll every second.
set -uo pipefail

# True if there's a capture source the recorder can actually use.
usable_mic() {
  command -v wpctl >/dev/null 2>&1 || return 0   # can't tell → assume ok
  # A Bluetooth audio device connected → the HFP mic path is available.
  if wpctl status 2>/dev/null | grep -q '\[bluez5\]'; then
    return 0
  fi
  # Otherwise rely on the default source being a real device (USB mic, webcam, dock…),
  # not the dead internal SoundWire/SOF mic.
  local name
  name=$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | sed -n 's/.*node.name = "\(.*\)".*/\1/p')
  [ -n "$name" ] || return 1
  case "$name" in
    *sof_sdw*) return 1 ;;   # dead internal Panther Lake mic
    *) return 0 ;;
  esac
}

if systemctl --user is-active --quiet dictation-rec; then
  printf '{"alt":"recording","tooltip":"Dictation: recording — click to stop"}'
elif ! systemctl --user is-active --quiet whisper-npu; then
  printf '{"alt":"down","tooltip":"Dictation server is DOWN — systemctl --user start whisper-npu"}'
elif ! usable_mic; then
  printf '{"alt":"nomic","tooltip":"No microphone — connect a headset or USB mic"}'
else
  printf '{"alt":"idle","tooltip":"Dictation ready — click or press the Assistant button to start"}'
fi
