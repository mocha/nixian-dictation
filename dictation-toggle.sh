# dictation-toggle — push-to-toggle local dictation on the Intel NPU.
#
# NOTE: this is the *body* consumed by writeShellApplication (pkgs/dictation/default.nix),
# which prepends the bash shebang, the runtimeInputs PATH, and `set -euo pipefail`.
# Do not add a shebang or `set` here (keeps shellcheck happy at build time).
#
# Flow:
#   START : force the active Bluetooth card to HFP/mSBC (16k mono == Whisper input), then
#           record via pw-record inside a TRANSIENT systemd --user unit so the recording
#           survives this keybind process exiting (you can roam between windows).
#   STOP  : `systemctl --user stop` sends SIGINT (KillSignal) so pw-record finalizes the WAV
#           and blocks until it exits; POST the WAV raw to the warm NPU server; copy the text;
#           paste via the focused app's own paste shortcut; restore the previous BT profile.
#
# Env overrides: DICTATION_MODEL, DICTATION_MAX_SECONDS, DICTATION_WRAP=auto|always|never,
#                DICTATION_NOPASTE=1 (copy only).

DIR="${XDG_RUNTIME_DIR:-/tmp}/dictation"
mkdir -p "$DIR"
WAV="$DIR/rec.wav"
CARDF="$DIR/card"
PROFF="$DIR/prevprofile"
PLAYERSF="$DIR/players"   # MPRIS players we paused on START, to resume on STOP
UNIT="dictation-rec"
MODEL="${DICTATION_MODEL:-whisper-small.en-fp16-ov}"
URL="http://127.0.0.1:8009/transcribe/$MODEL"
MAX="${DICTATION_MAX_SECONDS:-300}"

note() { notify-send -t 5000 -a dictation "Dictation" "$1" 2>/dev/null || true; }

# Resume exactly the media players we paused on START (see pause block below). Safe to call
# on any STOP/cleanup path — a no-op if we paused nothing.
resume_players() {
  [ -f "$PLAYERSF" ] || return 0
  if command -v playerctl >/dev/null 2>&1; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      playerctl -p "$p" play 2>/dev/null || true
    done <"$PLAYERSF"
  fi
  rm -f "$PLAYERSF"
}

# Single-instance guard. CRITICAL: close fd 9 (`9>&-`) wherever we spawn a daemonizing
# child — wl-copy forks and would otherwise inherit this fd and hold the lock forever,
# silently wedging every later run. A racing double-press is told it's busy, not dropped.
exec 9>"$DIR/lock"
flock -n 9 || { note "Dictation busy (another run in progress)"; exit 0; }

is_terminal() {
  case "$1" in
    com.mitchellh.ghostty | kitty | org.wezfurlong.wezterm | Alacritty) return 0 ;;
    *) return 1 ;;
  esac
}

# Wrap dictated text so agent harnesses know it's voice input (may contain transcription
# errors). auto (default): wrap only terminal/agent targets; always|never override.
wrap() {
  local t="$1" cls="$2" mode="${DICTATION_WRAP:-auto}"
  case "$mode" in
    never)  printf '%s' "$t"; return ;;
    always) printf '<dictated_note>\n%s\n</dictated_note>' "$t"; return ;;
  esac
  if is_terminal "$cls"; then
    printf '<dictated_note>\n%s\n</dictated_note>' "$t"
  else
    printf '%s' "$t"
  fi
}

# Copy the (possibly wrapped) text, then send the focused app's paste chord. cliphist's
# watcher archives whatever we copy, so transcripts land in history for free.
deliver() {
  local raw="$1" cls out
  cls=$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // empty')
  out=$(wrap "$raw" "$cls")
  printf '%s' "$out" | wl-copy 9>&-   # 9>&- : don't let wl-copy's daemon inherit/hold the lock
  if [ -n "${DICTATION_NOPASTE:-}" ]; then
    note "Copied (no-paste)"
    return
  fi
  sleep 0.12 # let clipboard settle / focus stabilize
  if is_terminal "$cls"; then
    if wtype -M ctrl -M shift -k v -m shift -m ctrl 2>/dev/null; then
      note "Pasted dictated_note -> $cls"
    else
      note "Copied (paste failed)"
    fi
    return
  fi
  case "$cls" in
    dev.zed.Zed | firefox | org.mozilla.firefox | chromium-browser | Google-chrome | obsidian | Slack | vesktop | discord)
      if wtype -M ctrl -k v -m ctrl 2>/dev/null; then
        note "Pasted -> $cls"
      else
        note "Copied (paste failed)"
      fi
      ;;
    *)
      note "Copied to clipboard (paste manually -- ${cls:-unknown})"
      ;;
  esac
}

# ---- STOP branch: a recording is in flight --------------------------------
if systemctl --user is-active --quiet "$UNIT"; then
  systemctl --user stop "$UNIT" 2>/dev/null || true # KillSignal=SIGINT → clean WAV; blocks until exit
  if [ -f "$CARDF" ] && [ -f "$PROFF" ] && [ -s "$PROFF" ]; then
    pactl set-card-profile "$(cat "$CARDF")" "$(cat "$PROFF")" 2>/dev/null || true
  fi
  rm -f "$CARDF" "$PROFF"
  resume_players   # A2DP is back — resume whatever we paused, before the (slower) transcribe

  if [ ! -s "$WAV" ] || [ "$(stat -c%s "$WAV" 2>/dev/null || echo 0)" -lt 4096 ]; then
    note "No audio captured (headset disconnected?)"
    exit 0
  fi
  if ! json=$(curl --fail --max-time 60 -sS -H 'Content-Type: audio/wav' \
    --data-binary @"$WAV" -X POST "$URL"); then
    note "Transcription failed / server cold"
    exit 0
  fi
  text=$(printf '%s' "$json" | jq -r '.text // empty' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -z "$text" ]; then
    note "No text ($(printf '%s' "$json" | jq -r '.error // "empty response"'))"
    exit 0
  fi
  deliver "$text"
  exit 0
fi

# ---- START branch: begin a recording --------------------------------------
if ! systemctl --user is-active --quiet whisper-npu; then
  note "Dictation server is down (whisper-npu not running)"
  exit 1
fi
# Pick a capture source. Prefer a Bluetooth headset (force HFP/mSBC == 16k mono Whisper input);
# if none is connected, fall back to the default PipeWire source (USB mic, webcam, dock…) and
# skip the BT profile dance entirely. Either way the dead internal Panther Lake mic (…sof_sdw…)
# is rejected — there's no working capture on it.
card=$(pactl list short cards | awk '/bluez_card/{print $2; exit}')
if [ -n "${card:-}" ]; then
  # --- Bluetooth path: steal the A2DP link for an HFP mic ---------------------
  echo "$card" >"$CARDF"
  # remember the card's current active profile so we can restore it on stop
  pactl list cards | awk -v c="Name: $card" 'index($0, c){f=1} f && /Active Profile:/{print $3; exit}' >"$PROFF" || true

  # Pause any actively-playing media (Spotify, browser, …) BEFORE we steal the A2DP link for the
  # HFP mic — a clean MPRIS pause keeps the track's position instead of letting it run into a dead
  # sink. Record exactly which players we paused so STOP resumes just those (not ones already paused).
  : >"$PLAYERSF"
  if command -v playerctl >/dev/null 2>&1; then
    playerctl -l 2>/dev/null | while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ "$(playerctl -p "$p" status 2>/dev/null)" = "Playing" ] || continue
      playerctl -p "$p" pause 2>/dev/null && printf '%s\n' "$p" >>"$PLAYERSF"
    done
  fi

  pactl set-card-profile "$card" headset-head-unit-msbc 2>/dev/null ||
    pactl set-card-profile "$card" headset-head-unit 2>/dev/null || true

  # the source bound to THIS card shares its MAC: bluez_card.<MAC> → bluez_input.<MAC>*
  mac=${card#bluez_card.}
  src=""
  for _ in $(seq 1 30); do
    src=$(pactl list short sources | awk -v m="$mac" 'index($2, m){print $2; exit}')
    [ -n "$src" ] && break
    sleep 0.1
  done
  if [ -z "$src" ]; then
    note "HFP mic did not come up"
    # undo: restore the A2DP profile and resume anything we paused, so a failed start is invisible
    [ -s "$PROFF" ] && pactl set-card-profile "$card" "$(cat "$PROFF")" 2>/dev/null || true
    resume_players
    rm -f "$CARDF" "$PROFF"
    exit 1
  fi
else
  # --- Non-Bluetooth path: record from the default source (USB mic / webcam) --
  # No A2DP link to steal and the mic is a separate device, so there's nothing to pause and
  # no card profile to touch/restore. Clear any stale BT state so STOP stays a clean no-op.
  rm -f "$CARDF" "$PROFF" "$PLAYERSF"
  src=$(pactl get-default-source 2>/dev/null || true)
  case "${src:-}" in
    "")
      note "No microphone available"
      exit 1 ;;
    *sof_sdw*)
      note "No usable mic (internal mic is dead — connect a headset or USB mic)"
      exit 1 ;;
  esac
fi

# Record inside a transient user unit so it survives this process exiting. SIGINT on stop
# finalizes the WAV; RuntimeMaxSec caps a forgotten recording. Absolute pw-record path so
# the systemd user manager (different PATH) can find it.
pwrec=$(command -v pw-record)
rm -f "$WAV"
systemctl --user reset-failed "$UNIT" 2>/dev/null || true
systemd-run --user --quiet --collect --unit="$UNIT" \
  --property=KillSignal=SIGINT \
  --property=RuntimeMaxSec="$MAX" \
  -- "$pwrec" --target "$src" --rate 16000 --channels 1 --format s16 "$WAV"
note "Recording... (SUPER+D to stop, ${MAX}s cap)"
