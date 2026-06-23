#!/usr/bin/env bash
# Emits JSON state for the Wayle "dictation" custom module (consumed via icon-map/alt).
#   down      -> whisper-npu server not running
#   recording -> a capture is in flight (dictation-rec unit active)
#   idle      -> server up, ready to record
# Cheap (systemctl only, no HTTP) so it's safe to poll frequently.
set -uo pipefail

if systemctl --user is-active --quiet dictation-rec; then
  printf '{"alt":"recording","tooltip":"Dictation: recording — click to stop"}'
elif systemctl --user is-active --quiet whisper-npu; then
  printf '{"alt":"idle","tooltip":"Dictation ready — click or press the Assistant button to start"}'
else
  printf '{"alt":"down","tooltip":"Dictation server is DOWN — systemctl --user start whisper-npu"}'
fi
