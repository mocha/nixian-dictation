# dictation-toggle — push-to-toggle local dictation on the Intel NPU.
#
# NOTE: this is the *body* consumed by writeShellApplication (pkgs/dictation/default.nix),
# which prepends the bash shebang, the runtimeInputs PATH, and `set -euo pipefail`.
# Do not add a shebang or `set` here (keeps shellcheck happy at build time).
#
# Flow:
#   START : force the active Bluetooth card to HFP/mSBC (16k mono == Whisper input), then
#           record via pw-record inside a TRANSIENT systemd --user unit so the recording
#           survives this keybind process exiting (you can roam between windows). Once the
#           unit is confirmed active, fire a detached POST to the server's /warm endpoint so a
#           cold NPU pipeline compiles while you're still talking, not after you stop; then show
#           a persistent "Recording..." notification (note_start) that stays up until you
#           dismiss it or STOP replaces it with the outcome (note_done).
#   STOP  : `systemctl --user stop` sends SIGINT (KillSignal) so pw-record finalizes the WAV
#           and blocks until it exits; POST the WAV raw to the warm NPU server; copy the text;
#           paste via the focused app's own paste shortcut; restore the previous BT profile.
#
# Env overrides: DICTATION_MODEL, DICTATION_MAX_SECONDS (empty/0 = no cap, the default),
#                DICTATION_HTTP_TIMEOUT (transcribe POST timeout, seconds), DICTATION_WRAP=auto|always|never,
#                DICTATION_NOPASTE=1 (copy only), DICTATION_NOSOUND=1 (no start/stop chime),
#                DICTATION_SOUNDS (sound dir), DICTATION_SND_START / DICTATION_SND_STOP (filenames),
#                DICTATION_ARCHIVE=0 / DICTATION_ARCHIVE_DIR (recording retention; see below),
#                DICTATION_AUTOSTOP_SILENCE=<seconds> (opt-in: end the recording after N seconds of
#                  trailing silence; empty/0 = off, the default) + DICTATION_AUTOSTOP_THRESHOLD
#                  (silence RMS threshold 0..1, default 0.005),
#                DICTATION_STREAM=1 (opt-in: transcribe long dictations in chunks as you speak, for
#                  near-instant paste at stop; default off) + DICTATION_STREAM_CHUNK (target segment
#                  seconds, default 30), DICTATION_STREAM_MAXCHUNK (hard cap, default 45),
#                  DICTATION_STREAM_QUIET (snap-to-quiet RMS threshold, default 0.05).

DIR="${XDG_RUNTIME_DIR:-/tmp}/dictation"
mkdir -p "$DIR"
WAV="$DIR/rec.wav"
CARDF="$DIR/card"
PROFF="$DIR/prevprofile"
PLAYERSF="$DIR/players"   # MPRIS players we paused on START, to resume on STOP
WATCHF="$DIR/watch"       # marker: a detached __watch process owns finalize (streaming/auto-stop)
NOTIFYIDF="$DIR/notify_id" # id of the persistent "Recording..." notification (see note_start/note_done)
UNIT="dictation-rec"
MODEL="${DICTATION_MODEL:-whisper-small.en-fp16-ov}"
BASE_URL="http://127.0.0.1:8009"
URL="$BASE_URL/transcribe/$MODEL"
WARM_URL="$BASE_URL/warm/$MODEL"
# No recording cap by default: when RuntimeMaxSec fires it just kills the transient unit, so the
# STOP branch (which POSTs the WAV + pastes) never runs and the audio is silently lost. Set
# DICTATION_MAX_SECONDS=<seconds> to re-add a safety cap (with that same drop-on-expiry caveat).
MAX="${DICTATION_MAX_SECONDS:-}"
# Transcription POST timeout. Long dictations (30 min+) take well over a minute on the NPU, so this
# is generous; it only bounds a genuinely stuck/cold server.
HTTP_TIMEOUT="${DICTATION_HTTP_TIMEOUT:-900}"
# Best-effort start/stop chimes (freedesktop sounds, played via pw-record's sibling pw-play). @SOUNDS@
# is the sound-theme-freedesktop store path, substituted at build time by default.nix.
SOUNDS="${DICTATION_SOUNDS:-@SOUNDS@}"
SND_START="${DICTATION_SND_START:-message.oga}"
SND_STOP="${DICTATION_SND_STOP:-complete.oga}"

# Archive each finalized recording (audio + transcript) to a browsable, persistent dir so a
# failed transcription never loses the audio (cliphist only keeps the resulting text, and the
# live rec.wav lives in tmpfs and is clobbered every run). DICTATION_ARCHIVE=0 disables it;
# DICTATION_ARCHIVE_DIR overrides the location. Pruning of files older than the retention window
# is handled out-of-band by the dictation-prune systemd --user timer, not here.
ARCHIVE="${DICTATION_ARCHIVE:-1}"
ARCHIVE_DIR="${DICTATION_ARCHIVE_DIR:-$HOME/Recordings/Dictation}"

# Opt-in auto-stop: when set to a positive number of seconds, record via sox (instead of pw-record)
# and let it end the recording after that much trailing silence — then a detached watcher runs the
# normal transcribe+paste. Empty/0 = off (default), because deliberate think-pauses shouldn't cut a
# dictation short. THRESHOLD is the sox silence level (percent of full scale) for both leading-trim
# and trailing-stop.
AUTOSTOP="${DICTATION_AUTOSTOP_SILENCE:-}"
# Silence threshold as an RMS amplitude (0..1): a 1s window below this counts as silence. Measured
# on this hardware's Bluetooth capture: speech RMS ~0.05-0.45, silence floor ~0.0004 — so 0.005 sits
# cleanly in the gap. Raise if a noisy room keeps it recording; lower if it stops while you're still
# faintly talking.
AUTOSTOP_RMS="${DICTATION_AUTOSTOP_THRESHOLD:-0.005}"

# Opt-in live streaming: while you dictate, transcribe the audio in chunks as it accumulates so the
# final paste is near-instant on long dictations (short clips are already sub-second — this only pays
# off as clips grow). DICTATION_STREAM=1 enables it (default off); independent of auto-stop, and when
# either is on a detached __watch process owns finalize.
#
# Chunking is TIME-BASED, snapped to the quietest nearby moment — NOT pure silence detection. (A
# corpus of real dictation showed silence gaps are too unreliable to cut on: some recordings pause
# every ~20s, others never go quiet for 2s at all. But a low-energy dip is almost always available
# within a few seconds of any point, so snapping a time-based cut to the local RMS minimum lands
# clean boundaries without depending on the speaker to pause.) A segment closes once it reaches
# STREAM_CHUNK seconds AND the current 1s window is "quiet" (RMS < STREAM_QUIET); if no quiet window
# appears by STREAM_MAXCHUNK seconds, it force-cuts at the quietest window seen since STREAM_CHUNK.
# On any per-segment POST failure the watcher falls back to transcribing the whole WAV at stop, so
# streaming is a pure latency win that can't lose words.
STREAM="${DICTATION_STREAM:-0}"
STREAM_CHUNK="${DICTATION_STREAM_CHUNK:-30}"       # target segment length (s) before seeking a cut
STREAM_MAXCHUNK="${DICTATION_STREAM_MAXCHUNK:-45}" # hard cap (s): force a cut even if nothing quieted
STREAM_QUIET="${DICTATION_STREAM_QUIET:-0.05}"     # RMS below which a 1s window is a snap-able dip
streamed=0          # set by the __watch process only when it actually streamed segments
stream_text=""      # accumulated per-segment transcripts (built up inside the __watch process)
stream_failed=0     # a segment POST failed → finalize falls back to whole-WAV transcription

note() { notify-send -t 5000 -a dictation "Dictation" "$1" 2>/dev/null || true; }

# Persistent "recording in progress" notification: -t 0 means it never auto-expires, so it's a
# clear, standing visual indicator until either the user dismisses it manually or note_done()
# below replaces it with the actual outcome at STOP. -p prints the notification id, stashed so a
# *different* process (the STOP branch, or the detached __watch) can replace the right one.
note_start() {
  local id
  id=$(notify-send -t 0 -p -a dictation "Dictation" "$1" 2>/dev/null) || return 0
  [ -n "$id" ] && printf '%s' "$id" >"$NOTIFYIDF"
}

# The concluding notification for a recording (delivered/failed/empty/etc). Replaces the
# note_start() notification if it's still up (or starts a fresh one if the user already dismissed
# it -- notify-send just creates a new notification for an unknown replace-id, same net effect),
# then consumes the id so unrelated note() calls (busy, server-down, ...) never touch it.
note_done() {
  local id=""
  [ -s "$NOTIFYIDF" ] && id=$(cat "$NOTIFYIDF" 2>/dev/null)
  rm -f "$NOTIFYIDF"
  if [ -n "$id" ]; then
    notify-send -t 5000 -r "$id" -a dictation "Dictation" "$1" 2>/dev/null || note "$1"
  else
    note "$1"
  fi
}

# Audible cue, best-effort and non-blocking. setsid detaches it so it outlives this keybind process;
# 9>&- keeps the detached player from inheriting/holding the single-instance lock (see fd 9 below).
# Guarded on everything so a missing file/player/theme is a silent no-op, never an error.
chime() {
  [ -n "${DICTATION_NOSOUND:-}" ] && return 0
  local f="$SOUNDS/$1"
  [ -r "$f" ] || return 0
  command -v pw-play >/dev/null 2>&1 || return 0
  setsid pw-play "$f" >/dev/null 2>&1 9>&- &
}

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

# Archive the finalized recording to a persistent, browsable dir. Best-effort: archiving must
# never block delivery. archive_wav() copies the audio and sets archive_base; archive_txt() then
# drops the matching transcript (or a failure marker) alongside it, as:
#   <ARCHIVE_DIR>/dictation-YYYYMMDD-HHMMSS.{wav,txt}
archive_base=""
archive_wav() {
  [ "$ARCHIVE" = "0" ] && return 0
  if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
    note "Archive dir unavailable: $ARCHIVE_DIR"
    return 0
  fi
  archive_base="$ARCHIVE_DIR/dictation-$(date +%Y%m%d-%H%M%S)"
  cp -- "$WAV" "$archive_base.wav" 2>/dev/null || archive_base=""
}
archive_txt() {
  [ -n "$archive_base" ] || return 0
  printf '%s\n' "$1" >"$archive_base.txt" 2>/dev/null || true
}

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
    always) printf '<dictation>\n%s\n</dictation>' "$t"; return ;;
  esac
  if is_terminal "$cls"; then
    printf '<dictation>\n%s\n</dictation>' "$t"
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
    note_done "Copied (no-paste)"
    return
  fi
  sleep 0.12 # let clipboard settle / focus stabilize
  if is_terminal "$cls"; then
    if wtype -M ctrl -M shift -k v -m shift -m ctrl 2>/dev/null; then
      note_done "Pasted dictation -> $cls"
    else
      note_done "Copied (paste failed)"
    fi
    return
  fi
  case "$cls" in
    dev.zed.Zed | firefox | org.mozilla.firefox | chromium-browser | Google-chrome | obsidian | Slack | vesktop | discord)
      if wtype -M ctrl -k v -m ctrl 2>/dev/null; then
        note_done "Pasted -> $cls"
      else
        note_done "Copied (paste failed)"
      fi
      ;;
    *)
      note_done "Copied to clipboard (paste manually -- ${cls:-unknown})"
      ;;
  esac
}

# Finalize a just-ended recording: restore the BT profile, resume media, chime, then archive +
# transcribe + paste. Called by the manual STOP branch (normal mode) and by the __watch process
# (auto-stop mode). Assumes the recording unit is already stopped/inactive; returns (never exits)
# so callers keep control of flow.
finalize() {
  if [ -f "$CARDF" ] && [ -f "$PROFF" ] && [ -s "$PROFF" ]; then
    pactl set-card-profile "$(cat "$CARDF")" "$(cat "$PROFF")" 2>/dev/null || true
  fi
  rm -f "$CARDF" "$PROFF"
  resume_players   # A2DP is back — resume whatever we paused, before the (slower) transcribe
  chime "$SND_STOP"   # audible "recording stopped" — fires before the (slower) transcribe/paste

  if [ ! -s "$WAV" ] || [ "$(stat -c%s "$WAV" 2>/dev/null || echo 0)" -lt 4096 ]; then
    note_done "No audio captured (headset disconnected?)"
    return 0
  fi

  archive_wav   # persist the audio now, before transcription — any failure past here keeps the .wav

  local json text
  if [ "$streamed" = "1" ] && [ "$stream_failed" = "0" ]; then
    # Streaming succeeded: segments were transcribed live as they closed. Deliver the stitched
    # result — no whole-WAV POST needed, so the paste is near-instant.
    text="$stream_text"
    if [ -z "$text" ]; then
      archive_txt "[no transcript — streaming produced no text]"
      note_done "No text (stream empty)"
      return 0
    fi
  else
    # Normal mode, or streaming that hit a failed segment: transcribe the whole WAV in one shot.
    if ! json=$(curl --fail --max-time "$HTTP_TIMEOUT" -sS -H 'Content-Type: audio/wav' \
      --data-binary @"$WAV" -X POST "$URL"); then
      archive_txt "[transcription failed — server cold/unreachable; audio saved to this .wav for manual re-run]"
      note_done "Transcription failed / server cold (audio saved)"
      return 0
    fi
    text=$(printf '%s' "$json" | jq -r '.text // empty' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "$text" ]; then
      archive_txt "[no transcript — empty/error response: $(printf '%s' "$json" | jq -r '.error // "empty"')]"
      note_done "No text ($(printf '%s' "$json" | jq -r '.error // "empty response"'))"
      return 0
    fi
  fi
  archive_txt "$text"
  deliver "$text"
}

# Transcribe one closed speech segment [start,end) of the growing WAV and append it to stream_text.
# Runs inside the detached __watch process (streaming mode). Slices the raw PCM byte range — the file
# only grows and this range is already written, so reading it while pw-record still appends is safe —
# wraps it as a WAV via sox, and POSTs it to the warm NPU exactly like a full recording (the server's
# front-trim strips the slice's leading/trailing silence). Any failure sets stream_failed so finalize
# falls back to transcribing the whole WAV; streaming never drops words.
flush_segment() {
  local start="$1" end="$2"
  local len=$((end - start)) seg json text
  [ "$len" -gt 4096 ] || return 0   # skip sub-~128ms slivers — not worth a round-trip
  seg="$DIR/seg.wav"
  # dd (not tail|head) reads exactly [start,start+len) — its byte-granular skip/count avoids the
  # SIGPIPE that head's early close would raise on tail, which pipefail would misread as a failure.
  if ! dd if="$WAV" bs=1M skip="$start" count="$len" iflag=skip_bytes,count_bytes 2>/dev/null \
       | sox -t raw -r 16000 -e signed -b 16 -c 1 - -t wav "$seg" 2>/dev/null; then
    stream_failed=1
    return 0
  fi
  if ! json=$(curl --fail --max-time "$HTTP_TIMEOUT" -sS -H 'Content-Type: audio/wav' \
       --data-binary @"$seg" -X POST "$URL" 2>/dev/null); then
    stream_failed=1
    rm -f "$seg"
    return 0
  fi
  rm -f "$seg"
  text=$(printf '%s' "$json" | jq -r '.text // empty' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$text" ] && stream_text="${stream_text:+$stream_text }$text"
}

# ---- Auto-stop watcher (internal) -----------------------------------------
# Launched detached (setsid) by the START branch when auto-stop is on. pw-record keeps writing the
# WAV (the proven capture path); this watcher just polls the file's tail. Each second it reads the
# last ~1s of PCM (tail bytes → sox raw `stat` for RMS) and, once speech has actually been heard,
# stops the recording after AUTOSTOP seconds of continuous silence (RMS < AUTOSTOP_RMS). A manual
# toggle ending the unit early just breaks the loop. Runs BEFORE the single-instance lock on purpose,
# so a manual early-stop press isn't told "busy". sox here only analyzes a file — it never captures.
if [ "${1:-}" = "__watch" ]; then
  autostop_on=0
  { [ -n "$AUTOSTOP" ] && [ "$AUTOSTOP" != "0" ]; } && autostop_on=1
  [ "$STREAM" = "1" ] && streamed=1   # tells finalize (in THIS process) to deliver the stitched text
  cut=44          # first unflushed byte; 44 = canonical WAV header (PCM data starts here)
  sil=0           # consecutive silent ticks (drives auto-stop)
  heard=0         # armed once real speech is seen (so a pre-talk pause never auto-stops)
  seg_active=0    # speech has occurred since the last cut (don't POST a silence-only segment)
  cand_sz=0       # byte offset of the quietest 1s window seen since this segment hit STREAM_CHUNK,
  cand_rms=""     #   with its RMS — the fallback cut point if none drops below STREAM_QUIET
  chunk_b=$((STREAM_CHUNK * 32000))
  max_b=$((STREAM_MAXCHUNK * 32000))
  while systemctl --user is-active --quiet "$UNIT"; do
    sleep 1
    sz=$(stat -c%s "$WAV" 2>/dev/null || echo "$cut")
    # last 1s of s16le mono 16k audio = 32000 bytes; interpret raw (skips the WAV-header question)
    rms=$(tail -c 32000 "$WAV" 2>/dev/null \
          | sox -t raw -r 16000 -e signed -b 16 -c 1 - -n stat 2>&1 \
          | awk -F: '/RMS.*amplitude/{gsub(/ /,"",$2); print $2}')
    [ -n "$rms" ] || continue
    if awk -v r="$rms" -v t="$AUTOSTOP_RMS" 'BEGIN{exit !(r+0 < t+0)}'; then
      sil=$((sil + 1))
    else
      sil=0
      heard=1       # only arm auto-stop after real speech, so the pre-talk pause never triggers it
      seg_active=1
    fi
    # streaming: once a segment reaches STREAM_CHUNK, cut at the next quiet window — or, at the
    # STREAM_MAXCHUNK cap, at the quietest window seen so far. Contiguous byte offsets ([cut,cutat))
    # mean every byte lands in exactly one segment — no words lost, no overlap/duplication.
    if [ "$STREAM" = "1" ] && [ "$seg_active" = "1" ] && [ "$((sz - cut))" -ge "$chunk_b" ]; then
      if [ "$cand_sz" = "0" ] || awk -v r="$rms" -v c="$cand_rms" 'BEGIN{exit !(r+0 < c+0)}'; then
        cand_rms="$rms"; cand_sz="$sz"
      fi
      cutat=0
      if awk -v r="$rms" -v t="$STREAM_QUIET" 'BEGIN{exit !(r+0 < t+0)}'; then
        cutat="$sz"        # quiet enough → cut here; nothing carries into the next segment
      elif [ "$((sz - cut))" -ge "$max_b" ]; then
        cutat="$cand_sz"   # forced cut → the quietest window seen (audio after it carries over)
      fi
      if [ "$cutat" != "0" ]; then
        flush_segment "$cut" "$((cutat - cut))"
        cut="$cutat"; cand_sz=0; cand_rms=""
        [ "$cutat" -ge "$sz" ] && seg_active=0   # cut at "now" → wait for fresh speech
      fi
    fi
    # auto-stop: end the whole recording after the (longer) trailing-silence window
    if [ "$autostop_on" = "1" ] && [ "$heard" = "1" ] && [ "$sil" -ge "$AUTOSTOP" ]; then
      systemctl --user stop "$UNIT" 2>/dev/null || true   # trailing silence reached → end recording
      break
    fi
  done
  # The unit may still be finalizing the WAV (a manual stop ends it out from under this loop); a
  # blocking stop guarantees pw-record has flushed the tail before we read it for the last segment.
  systemctl --user stop "$UNIT" 2>/dev/null || true
  if [ "$STREAM" = "1" ] && [ "$seg_active" = "1" ]; then
    sz=$(stat -c%s "$WAV" 2>/dev/null || echo "$cut")
    flush_segment "$cut" "$sz"   # trailing segment: speech that never hit a closing gap
  fi
  rm -f "$WATCHF" "$DIR/seg.wav"
  finalize
  exit 0
fi

# Single-instance guard. CRITICAL: close fd 9 (`9>&-`) wherever we spawn a daemonizing child —
# wl-copy forks and would otherwise inherit this fd and hold the lock forever, silently wedging
# every later run. A racing double-press is told it's busy, not dropped.
exec 9>"$DIR/lock"
flock -n 9 || { note "Dictation busy (another run in progress)"; exit 0; }

# ---- STOP branch: a recording is in flight --------------------------------
if systemctl --user is-active --quiet "$UNIT"; then
  systemctl --user stop "$UNIT" 2>/dev/null || true # KillSignal=SIGINT → clean WAV; blocks until exit
  if [ -f "$WATCHF" ]; then
    # streaming/auto-stop mode: the detached watcher owns finalize (it's waiting for the unit to end).
    # We only needed to end the recording early — the watcher will flush + archive + transcribe + paste.
    exit 0
  fi
  finalize
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
# finalizes the WAV. RuntimeMaxSec is only added when DICTATION_MAX_SECONDS is set — by default
# there's no cap, because expiry kills the unit without running the STOP branch (audio is lost).
# Absolute recorder paths so the systemd user manager (different PATH) can find them.
rm -f "$WAV" "$WATCHF" "$DIR/seg.wav" "$NOTIFYIDF"
systemctl --user reset-failed "$UNIT" 2>/dev/null || true
runargs=(--user --quiet --collect --unit="$UNIT" --property=KillSignal=SIGINT)
[ -n "$MAX" ] && runargs+=(--property=RuntimeMaxSec="$MAX")

pwrec=$(command -v pw-record)
systemd-run "${runargs[@]}" \
  -- "$pwrec" --target "$src" --rate 16000 --channels 1 --format s16 "$WAV"

# systemd-run returns once the transient unit is *queued*, not once pw-record has actually opened
# the device -- an invalid/vanished source fails inside the unit a beat later. Confirm it's really
# active before telling the user recording started; otherwise this notified "Recording..." while
# nothing was actually being captured (the tray icon already got this right, since it polls unit
# state directly -- this closes the gap in the notification).
started=0
for _ in $(seq 1 20); do
  systemctl --user is-active --quiet "$UNIT" && { started=1; break; }
  sleep 0.05
done
if [ "$started" != "1" ]; then
  if [ -f "$CARDF" ] && [ -s "$PROFF" ]; then
    pactl set-card-profile "$(cat "$CARDF")" "$(cat "$PROFF")" 2>/dev/null || true
  fi
  resume_players
  rm -f "$CARDF" "$PROFF"
  note "Recording failed to start (mic unavailable?)"
  exit 1
fi

# Kick the NPU model warm the moment recording actually begins -- not at STOP -- so a cold
# pipeline (first dictation after boot/suspend; see server.py's /warm) gets the whole length of
# the dictation as a head start instead of making STOP wait for it. Best-effort and detached:
# 9>&- keeps it from holding the instance lock; if this fails, the real transcribe POST at STOP
# just pays the cold-load cost like before.
setsid curl -fsS --max-time "$HTTP_TIMEOUT" -X POST "$WARM_URL" >/dev/null 2>&1 9>&- &

watch_active=0
if command -v sox >/dev/null 2>&1 \
   && { [ "$STREAM" = "1" ] || { [ -n "$AUTOSTOP" ] && [ "$AUTOSTOP" != "0" ]; }; }; then
  # Streaming and/or auto-stop both need the detached watcher: it polls rec.wav's tail once/sec,
  # closes speech segments for live transcription (streaming), and/or ends the recording after
  # trailing silence (auto-stop). The marker tells a manual STOP press to defer to that watcher
  # instead of finalizing itself. 9>&- keeps the detached watcher from holding the instance lock.
  : >"$WATCHF"
  setsid "$0" __watch >/dev/null 2>&1 9>&- &
  watch_active=1
fi
chime "$SND_START"   # audible "recording started"
autostop_note=""
[ "$watch_active" = "1" ] && [ -n "$AUTOSTOP" ] && [ "$AUTOSTOP" != "0" ] && autostop_note="auto-stop after ${AUTOSTOP}s silence, "
if [ "$watch_active" = "1" ] && [ "$STREAM" = "1" ]; then
  note_start "Recording... (live transcribe; ${autostop_note}toggle to stop)"
elif [ -n "$autostop_note" ]; then
  note_start "Recording... (${autostop_note}or toggle)"
elif [ -n "$MAX" ]; then
  note_start "Recording... (toggle to stop, ${MAX}s cap)"
else
  note_start "Recording... (toggle to stop)"
fi
