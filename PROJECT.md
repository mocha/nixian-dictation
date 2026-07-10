# nixian-dictation — Local NPU Dictation for the OmniBook

> **Status:** design v2 — **review feedback incorporated**, ready to implement on owner's go.
> v1 went to two independent model reviewers; their consensus fixes are folded in below and
> summarized in the changelog.

## Changelog (v1 → v2)

| # | Change | Source |
|---|---|---|
| 1 | **Raw `--data-binary` upload**, not multipart `-F audio=@` (upstream uses raw body; `{"text":...}`/`{"error":...}` response) | both reviewers, verified vs README |
| 2 | **Stop/finalize race fixed**: `pw-record` is not the stop-shell's child, so `wait $pid` is a no-op. Replaced with `kill -INT` + `kill -0` exit-poll + WAV size-stability poll | both reviewers |
| 3 | **Paste, not type**: `wl-copy` always, then synthesize the *paste shortcut* (per-app: `Ctrl+V`, terminals `Ctrl+Shift+V`) instead of key-by-key typing. Strip trailing newline to avoid auto-submit | owner clarification |
| 4 | **Terminals are the PRIMARY paste target** (agent harnesses), not deny-listed | owner |
| 5 | Default model **`small.en`** (was `base.en`); warm the *exact* model the script uses | both reviewers |
| 6 | **R2 raised to HIGH+**: upstream repo archived 2025-05-07 → pin image by digest, record model commit, plan to vendor the small Flask server after first proof | both reviewers |
| 7 | NixOS: machine is **already on 26.05**; `hardware.cpu.intel.npu.enable` exists and is **already `true`** — keep it (v1's "don't enable, it's a trap" note was stale) | Feedback 2 + verified `nixos-option` |
| 8 | `unitConfig.ConditionUser="deuley"`; verify OCI runtime is **crun** (`--group-add keep-groups` needs it); `--pull=never` after pinning | Feedback 1/2 |
| 9 | BT: **save & restore the previous profile** (not hardcoded `a2dp-sink`); select the `bluez_input` bound to the *specific* card we switched (match by MAC) | both reviewers |
| 10 | **`flock`** single-instance guard; ship the script via **`writeShellApplication`** with declared `runtimeInputs` (no reliance on "already present" tools) | Feedback 1 |
| 11 | **cliphist** added as the clipboard-history layer (transcripts auto-archived via `wl-paste --watch`; `SUPER+V` fuzzel recall picker; basis for a Wayle bar dropdown) | owner request |
| 12 | **Dictation provenance marker**: wrap text in `<dictated_note>…</dictated_note>` for terminal/agent targets so agents know it's voice input (may contain transcription errors); raw text elsewhere; consumer-side note in `~/.claude/CLAUDE.md` | owner idea |

## STATUS — NPU dictation working (as built, 2026-06-23)

**The NPU path works end-to-end.** Transcription runs on the Intel NPU (`Intel(R) AI Boost`)
at **~0.5 s for a 14 s clip (~28× real-time)** once warm; the model is pre-warmed at service
start (first cold call ~8 s for NPU graph compile). Only the **live Bluetooth-mic test**
remains (needs a headset + speech).

### What actually had to change vs. the v2 plan
The archived `mecattaf/whisper-npu-server` image **does not work on Panther Lake** — it bundles
OpenVINO 2024.6 + NPU driver 1.10, which enumerate **CPU only** (`available_devices == ['CPU']`)
on `8086:B03E`. Native-on-NixOS was also a dead end (nixpkgs `openvino` 2026.1 ships the NPU
*plugin*, but nixpkgs `intel-npu-driver` is built **without the compiler** `libnpu_driver_compiler.so`,
and enumeration never connected). So I **built a custom image** (`npu-image/`) with a current,
mutually-compatible stack:

| Piece | Pin | Note |
|---|---|---|
| Base | `ubuntu:24.04` | |
| NPU driver (UMD + compiler) | **linux-npu-driver v1.28.0** | first release with Panther Lake support; debs from the release tarball |
| level-zero **loader** | **oneapi-src v1.30.0** (`libze1`) | **the key fix** — Ubuntu's bundled `libze1` 1.16 is too old to load the 1.28 driver → NPU wouldn't enumerate |
| OpenVINO + GenAI | **2026.2.1** | `WhisperPipeline(model, "NPU", STATIC_PIPELINE=True)` |
| Model | **`OpenVINO/whisper-small.en-fp16-ov`** | 2024-era mecattaf IR fails the static NPU pipeline (`self_attn_nodes.empty()`); current OpenVINO export works |

### As-wired
- Image `localhost/whisper-npu-ptl:local` (built from `npu-image/Dockerfile`), run by the
  `whisper-npu` systemd **user** service; pre-warms `whisper-small.en-fp16-ov` on the NPU.
- `dictation-toggle` script (model `whisper-small.en-fp16-ov`), binds `SUPER+D` (toggle),
  `SUPER+SHIFT+D` (copy-only), `SUPER+SHIFT+V` (cliphist picker); cliphist watcher; the
  `~/.claude/CLAUDE.md` `<dictated_note>` consumer note.
- `server.py` is vendored + hardened in `npu-image/` (env-configurable device/model, `/health`,
  resilient pre-warm) — this **is** the R2 "vendor the Flask server" mitigation, done.

### Session-2 additions (UI, trigger, fixes) — all working
- **Trigger = the HP Assistant/Copilot button** (`SUPER+SHIFT+F23`). It physically sends F23
  with Super+Shift; `wev` shows `XF86Assistant` (shifted level) but Hyprland matches the **base
  keysym F23** — that mismatch is why `XF86Assistant` binds never fired. This lua DSL also can't
  bind `code:` keycodes and `hyprctl keyword` is disabled, so the keysym route is the only one.
  `SUPER+SHIFT+D` = copy-only, `SUPER+SHIFT+V` = cliphist picker.
- **Wayle bar module** `custom-dictation`: mic icon driven by `~/.config/hypr/scripts/dictation-status.sh`
  (down/idle/recording), click-to-toggle, red pulse while recording (styles/index.scss). Wayle
  config **consolidated into `config.toml`** (runtime.toml is the GUI overlay — emptied; it
  *overlays* config.toml, which is why hand-edits to config.toml looked ignored).
- **Lock-leak bug fixed (was the "unresponsive / no feedback" cause):** `wl-copy` daemonizes and
  inherited the script's `flock` fd, holding the lock forever so every later run silently hit
  `flock || exit 0`. Fixed with `wl-copy 9>&-`. Also added failure toasts (busy / server-down /
  no-headset / no-audio), 5 s timeout, and a server-up check at start.
- **Security:** server binds `127.0.0.1:8009` only (not on LAN). A Unix-socket hardening was
  offered (eliminates the TCP surface) — still open / undecided.

### Session-3 additions (start-failure notification, cold-start latency, persistent recording note)
- **Fixed false "Recording..." notification:** `systemd-run` returns once the transient unit is
  *queued*, not once `pw-record` has actually opened the device — an invalid/vanished source
  failed inside the unit a beat later while the script still reported success (the bar icon,
  which polls unit state directly, already got this right). START now polls `is-active` (up to
  ~1s) before notifying; on failure it restores the BT profile/resumes players and reports
  "Recording failed to start (mic unavailable?)" instead.
- **Cold-start latency:** the NPU model is already kept warm indefinitely (container never
  evicts it — see `ModelManager.pipelines`; host-side cgroup usage is ~33 MB, trivial, and
  nothing else on this box touches the NPU, so there's no reason not to). The real ~30s cold
  hit only happens once per container start (boot/login) or after anything that resets the NPU
  (e.g. suspend/resume). Added `POST /warm[/<model>]` to `server.py` (force-loads a model, no
  audio needed) and have `dictation-toggle` fire it detached the moment recording is confirmed
  started — so a cold pipeline compiles while the user is still talking instead of at STOP.
  **Requires an image rebuild + `systemctl --user restart whisper-npu`** to take effect (`server.py`
  is `COPY`'d into the image, not bind-mounted).
- **Persistent recording notification:** the "Recording..." toast used to auto-expire after 5s.
  It's now sent with `notify-send -t 0 -p` (never expires; id captured) via `note_start`, and
  replaced with the actual outcome (pasted/copied/failed/etc.) via `note_done` using
  `-r <id>` when the recording ends — so it's a standing visual indicator the whole time you're
  dictating, gone only once you dismiss it or the recording concludes.
- **Fixed mic-source mis-selection, in two rounds:** first found that the BT source match was a
  substring check on the MAC, so it could match this same card's `bluez_output.<MAC>.*.monitor`
  (the sink's loopback, not a mic) instead of `bluez_input.<MAC>` — every real dictation before
  this was almost certainly transcribing the *output* loopback, not the microphone. Switched to
  a prefix match on `bluez_input.` — but the soundcore Liberty 4 Pro exposes that source as
  `bluez_input.F4:9D:8A:79:5A:74` (colon-separated), while the card name and its own
  `bluez_output` monitor both use underscores (`bluez_card.F4_9D_8A_79_5A_74`) — so the naive
  prefix match on the raw (underscore) MAC never matched at all ("HFP mic did not come up"
  every time). Fixed by stripping `_`/`:` from both sides before comparing. Also hardened the
  non-Bluetooth path: `pactl get-default-source` can report the literal `@DEFAULT_SOURCE@`
  placeholder with no real node behind it, which `pw-record` fails on instantly
  ("no target node available") — now verified against an actual non-monitor source first.
- **Fixed a start-check race:** a transient `systemd-run` unit reads "active" the instant
  `pw-record` is forked, before it's finished connecting to PipeWire and can discover the
  target doesn't exist -- so the fix above (poll `is-active` before notifying "Recording...")
  still raced a fast failure. A failed unit dying in under a second also meant the *next*
  toggle press found nothing active and was read as a fresh START instead of STOP, so every
  press just launched another doomed recording (looked like recording "never stopped"). Added
  a 0.3s settle + recheck after the unit first reports active.

### Known follow-ups
- **Bluetooth stability:** the WH-1000XM5 audio link drops intermittently (Sony multipoint) — the
  most common real-world failure; not a tool bug.
- **Reproducibility:** the image is built imperatively from `npu-image/Dockerfile` and the model
  is an imperative `~/.whisper/models` download — not declarative like the rest of the config.
  Future: `pkgs.dockerTools` or a pinned build + scripted model fetch.
- **Live mic test** (below) is the only unverified step.
- Optional: try `whisper-small.en-int8-ov` for even lower NPU latency/memory.

## 1. Goal

A superwhisper-style flow on NixOS/Hyprland: press a shortcut to start recording, keep
talking while moving freely between windows (recorder runs **detached**), press again to
stop. Audio is transcribed **on the Intel NPU**, the text lands on the **clipboard**, and is
**pasted into the focused app** (via the app's own paste shortcut) when that app is a known
paste target. Fully local, no cloud ASR. Primary use: **dictating to agent harnesses in a
terminal**.

## 2. Environment (target machine)

### Hardware — HP OmniBook X Flip 14 (2-in-1 convertible)

| Component | Detail | Relevance |
|---|---|---|
| CPU | Intel **Core Ultra 7 356H** (Panther Lake), 16 threads | host |
| NPU | Intel NPU 5, **~50 TOPS**; PCI `8086:B03E` (subsys `103C:8EA4`); `/dev/accel/accel0` (`crw-rw-rw-`) | **inference target.** `intel_vpu` loaded; fw `vpu_50xx_v1.bin`; `level-zero` 1.28.5; `hardware.cpu.intel.npu.enable=true` already set |
| iGPU | Intel **Panther Lake** (Xe3), `/dev/dri/renderD128` (world-rw) | OpenVINO `GPU` fallback |
| Internal audio | SOF `sof-soundwire` (`HP…8EA4`), **TAS2783** smart-amp | **mic + speakers dead** (Panther Lake SoundWire/SOF firmware gap; zero internal capture sources). Reason the mic is Bluetooth. |
| Output audio | USB **Schiit 4490** DAC | output only |
| Bluetooth | enabled, `powerOnBoot`, `Experimental=true`. Paired: **WH-1000XM5**, **soundcore Liberty 4 Pro** (+ MX Master 4, 8BitDo) | **dictation mic** — script auto-detects the active BT card (HFP/mSBC) |

### Software stack

| Layer | Detail |
|---|---|
| OS | **NixOS 26.05** (Yarara), channel-based (no flake), `allowUnfree=true`. (`stateVersion="25.11"` is just the install stamp — running channel is 26.05.) |
| Session | **Hyprland** (Wayland) via `uwsm`+`ly`; **Lua** config (`~/.config/hypr/hyprland.lua`, `hl.bind`/`hl.dsp.*`) |
| Audio | **PipeWire 1.6.5** + WirePlumber |
| Shell/bar | **Wayle** (owns `org.freedesktop.Notifications` → `notify-send`) |
| Containers | none yet — this project adds **rootless podman** |
| Present CLI | `pw-record`, `wl-copy`/`wl-paste`, `jq`, `hyprctl`, `pactl`/`wpctl` |
| Added by project | `wtype`, `podman`, the `dictation-toggle` package |
| Privilege | root ops via **`pkexec`** (no tty for sudo) |

## 3. Engine decision

Run Intel's NPU Whisper as a **rootless-podman HTTP server**:
[`ghcr.io/mecattaf/whisper-npu-server`](https://github.com/mecattaf/whisper-npu-server) =
`openvino_genai.WhisperPipeline(device='NPU')` behind `POST /transcribe[/{model}]` (raw body
in, `{"text":...}` out, port 5000 in-container). Models in `~/.whisper/models`; needs
`/dev/accel/accel0` + `/dev/dri`.

**Why container over native nix:** it encapsulates the OpenVINO + level-zero + NPU-plugin
stack that's painful to assemble on NixOS. Native `openvino-genai` venv is worse (FHS wheels
+ NPU-plugin packaging); whisper.cpp's OpenVINO path accelerates only the encoder. Both kept
as fallbacks only.

**⚠ Supply-chain (R2, HIGH+):** the upstream repo (and the ellenhp original it forks) is
**archived/read-only since 2025-05-07** — treat the image as *frozen third-party infra*, not
a maintained platform. Mitigation: pin the GHCR image **by digest**, record the model repo
commit + LFS hashes, and **vendor/fork the small Flask server** into this repo after the
first working proof. (No native nix derivation yet — prove the flow first.)

## 4. Architecture

```
SUPER+D ─► dictation-toggle ──START──► save BT card profile, force HFP/mSBC (16k mono)
   (flock)                             └► pw-record (detached, bg) ─► rec.wav
        ─► dictation-toggle ──STOP───► SIGINT pw-record, poll for exit + size-stable
                                       └► curl --data-binary ─► whisper-npu-server (NPU)
                                          └► wl-copy  ─► send paste chord (per-app shortcut)
                                          └► restore previous BT profile

whisper-npu-server = rootless podman container, kept WARM by a systemd --user service.
First model load is 30–60 s, so the chosen model must be pre-warmed — never spawn per-utterance.
```

## 5. Implementation

### 5.1 NixOS config (`/etc/nixos/configuration.nix`)

```nix
virtualisation.podman.enable = true;            # pulls in virtualisation.containers; default OCI runtime = crun

# Rootless podman needs a subuid/subgid range — verified empty today (R1 blocker).
users.users.deuley.subUidRanges = [ { startUid = 100000; count = 65536; } ];
users.users.deuley.subGidRanges = [ { startGid = 100000; count = 65536; } ];
users.users.deuley.linger = true;               # keep the warm model across logout/boot

environment.systemPackages = with pkgs; [
  wtype                                          # paste-chord; Wayland virtual-keyboard, no daemon
  cliphist                                       # clipboard history (transcripts auto-archived) — §5.5
  fuzzel                                         # dmenu picker for cliphist recall (Catppuccin-themed)
  (callPackage ./pkgs/dictation { })             # the dictation-toggle binary (writeShellApplication, §5.3)
];

systemd.user.services.whisper-npu = {
  description = "Whisper NPU server (rootless podman, model kept warm)";
  wantedBy = [ "default.target" ];
  after = [ "default.target" ];
  unitConfig.ConditionUser = "deuley";           # don't run under other user managers
  serviceConfig = {
    ExecStartPre = "-${pkgs.podman}/bin/podman rm -f whisper-server";
    ExecStart = ''
      ${pkgs.podman}/bin/podman run --rm --replace --name whisper-server \
        --pull=never \
        -v %h/.whisper/models:/root/.whisper/models \
        -p 127.0.0.1:8009:5000 \
        --security-opt seccomp=unconfined --ipc=host --group-add keep-groups \
        --device=/dev/dri --device=/dev/accel/accel0 \
        ghcr.io/mecattaf/whisper-npu-server@sha256:<PIN_AFTER_FIRST_PULL>
    '';
    # Pre-warm the exact model the script uses so first dictation isn't a cold load:
    ExecStartPost = "-${pkgs.bash}/bin/bash -c 'for i in $(seq 1 60); do ${pkgs.curl}/bin/curl -fsS --data-binary @${pkgs.coreutils}/... ; done'"; # ⚠ see §5.2 note — likely simpler to warm via a tiny silent wav
    ExecStop = "${pkgs.podman}/bin/podman stop -t 10 whisper-server";
    Restart = "on-failure"; RestartSec = 5;
  };
};
```

Notes:
- **NPU module:** `hardware.cpu.intel.npu.enable` is already `true` on this 26.05 install —
  leave it. Do **not** add `/dev/accel` udev rules (nodes already world-rw). Do **not** use
  `virtualisation.oci-containers` (rootless path buggy; defaults to root → wrong `~/.whisper`).
- **Image is pinned by digest** + `--pull=never`; fill `<PIN_AFTER_FIRST_PULL>` from
  `podman inspect --format '{{.Digest}}'` after step 5.2.
- **Warm-up** is best done as a small explicit call (silent 1 s wav) rather than the inline
  hack above — finalize the exact form once `/models` confirms the model name (⚠ §5.2).

### 5.2 One-time bring-up (imperative — recorded here, not declarative)

```sh
podman pull ghcr.io/mecattaf/whisper-npu-server:latest
podman info --format '{{.Host.OCIRuntime.Name}}'        # expect: crun  (keep-groups needs it)
podman inspect --format '{{index .RepoDigests 0}}' ghcr.io/mecattaf/whisper-npu-server:latest  # → pin in §5.1

mkdir -p ~/.whisper/models
# fetch small.en per upstream README (HF, GIT_LFS_SKIP_SMUDGE=1); record the commit + LFS hashes.
systemctl --user daemon-reload && systemctl --user start whisper-npu
curl -s 127.0.0.1:8009/models                            # confirm exact model names + path
# smoke test the API contract (raw body):
curl --data-binary @some.wav -X POST http://127.0.0.1:8009/transcribe/whisper-small.en
```

### 5.3 The `dictation-toggle` script

Delivered as a Nix package (`/etc/nixos/pkgs/dictation/default.nix`) via
`writeShellApplication` with `runtimeInputs = [ pipewire wl-clipboard wtype jq curl
libnotify pulseaudio hyprland util-linux coreutils ]`, so every dependency is declared.
Authored/iterated here in `~/code/nixian-dictation/dictation-toggle.sh`. House conventions:
`set -euo pipefail`, state in `$XDG_RUNTIME_DIR`, `notify-send -a`, detect-then-act +
poll-until-ready (mirrors `squeek-toggle.sh`).

```sh
#!/usr/bin/env bash
# dictation-toggle — push-to-TOGGLE local dictation on the Intel NPU.
# Engine: warm rootless-podman whisper-npu-server (systemd USER service `whisper-npu`).
# Mic: Bluetooth headset (internal mic dead on Panther Lake). We force HFP/mSBC (16k mono
# == Whisper input) on the active BT card, record detached, then on stop SIGINT + poll,
# POST the wav raw, copy the text, and PASTE it via the focused app's own paste shortcut.
set -euo pipefail

DIR="${XDG_RUNTIME_DIR:-/tmp}/dictation"; mkdir -p "$DIR"
WAV="$DIR/rec.wav"; PIDF="$DIR/pid"; CARDF="$DIR/card"; PROFF="$DIR/prevprofile"
MODEL="whisper-small.en"                          # MUST match the pre-warmed model (§5.1)
URL="http://127.0.0.1:8009/transcribe/$MODEL"
MAX=120
exec 9>"$DIR/lock"; flock -n 9 || exit 0          # single-instance: ignore racing presses

note() { notify-send -t 3000 -a dictation "Dictation" "$1" 2>/dev/null || true; }

is_terminal() { case "$1" in com.mitchellh.ghostty|kitty|org.wezfurlong.wezterm|Alacritty) return 0;; *) return 1;; esac; }

# Provenance marker: wrap dictated text so agent harnesses know it's voice input that may
# contain transcription errors. DICTATION_WRAP = auto (default: wrap only terminal/agent
# targets) | always | never.
wrap() {
  local t="$1" cls="$2" mode="${DICTATION_WRAP:-auto}"
  case "$mode" in
    never)  printf '%s' "$t"; return;;
    always) printf '<dictated_note>\n%s\n</dictated_note>' "$t"; return;;
  esac
  if is_terminal "$cls"; then printf '<dictated_note>\n%s\n</dictated_note>' "$t"; else printf '%s' "$t"; fi
}

# Copy the (possibly wrapped) text, then send the focused app's own paste chord; copy-only
# if the class isn't a known paste target. cliphist's watcher archives whatever we copy.
deliver() {
  local raw cls out
  raw="$1"
  cls=$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // empty')
  out=$(wrap "$raw" "$cls")
  printf '%s' "$out" | wl-copy
  [ -n "${DICTATION_NOPASTE:-}" ] && { note "Copied (no-paste)"; return; }
  sleep 0.12                                       # let clipboard settle / focus stabilize
  if is_terminal "$cls"; then                      # terminals: Ctrl+Shift+V
    wtype -M ctrl -M shift -k v -m shift -m ctrl && note "Pasted ⟨dictated_note⟩ → $cls" || note "Copied (paste failed)"
  else case "$cls" in
    dev.zed.Zed|firefox|chromium-browser|Google-chrome|obsidian|Slack|vesktop|discord)  # Ctrl+V
      wtype -M ctrl -k v -m ctrl && note "Pasted → $cls" || note "Copied (paste failed)" ;;
    *)
      note "Copied to clipboard (paste manually — $cls)" ;;
  esac; fi
}

# ---- STOP branch ----------------------------------------------------------
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  pid=$(cat "$PIDF"); rm -f "$PIDF"
  kill -INT "$pid" 2>/dev/null || true            # SIGINT → pw-record flushes WAV header
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; sleep 0.2; fi
  prev=0; for _ in $(seq 1 20); do                # wait for file size to stabilize
    s=$(stat -c%s "$WAV" 2>/dev/null || echo 0); [ "$s" -gt 0 ] && [ "$s" = "$prev" ] && break; prev=$s; sleep 0.05; done
  # restore the previous BT profile
  [ -f "$CARDF" ] && [ -f "$PROFF" ] && pactl set-card-profile "$(cat "$CARDF")" "$(cat "$PROFF")" 2>/dev/null || true
  rm -f "$CARDF" "$PROFF"

  if [ ! -s "$WAV" ] || [ "$(stat -c%s "$WAV" 2>/dev/null || echo 0)" -lt 4096 ]; then
    note "No audio captured (headset disconnected?)"; exit 0; fi
  if ! json=$(curl --fail --max-time 60 -sS -H 'Content-Type: audio/wav' \
              --data-binary @"$WAV" -X POST "$URL"); then
    note "Transcription failed / server cold"; exit 0; fi
  text=$(printf '%s' "$json" | jq -r '.text // empty' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -z "$text" ] && { note "No text ($(printf '%s' "$json" | jq -r '.error // "empty"'))"; exit 0; }
  deliver "$text"
  exit 0
fi

# ---- START branch ---------------------------------------------------------
card=$(pactl list short cards | awk '/bluez_card/{print $2; exit}')
[ -z "${card:-}" ] && { note "No Bluetooth headset connected"; exit 1; }
echo "$card" > "$CARDF"
# remember current profile, then force HFP/mSBC
pactl list cards | awk -v c="$card" '$0 ~ "Name: "c{f=1} f&&/Active Profile:/{print $3; exit}' > "$PROFF" || true
pactl set-card-profile "$card" headset-head-unit-msbc 2>/dev/null \
  || pactl set-card-profile "$card" headset-head-unit 2>/dev/null || true
# the source bound to THIS card shares its MAC: bluez_card.<MAC> → bluez_input.<MAC>
mac=${card#bluez_card.}; src=""
for _ in $(seq 1 30); do
  src=$(pactl list short sources | awk -v m="$mac" '$0 ~ "bluez_input."m{print $2; exit}')
  [ -n "$src" ] && break; sleep 0.1; done
[ -z "$src" ] && { note "HFP mic did not come up"; exit 1; }

( sleep "$MAX"; [ -f "$PIDF" ] && dictation-toggle ) >/dev/null 2>&1 &   # runaway cap
pw-record --target "$src" --rate 16000 --channels 1 --format s16 "$WAV" &
echo $! > "$PIDF"
note "Recording… (SUPER+D to stop, ${MAX}s cap)"
```

### 5.4 Hyprland keybinds (`~/.config/hypr/hyprland.lua`)

```lua
-- start cliphist watching the clipboard (one-shot at session start)
hl.exec_cmd("wl-paste --watch cliphist store")

hl.bind(mainMod .. " + D", hl.dsp.exec_cmd("dictation-toggle"))
hl.bind(mainMod .. " + SHIFT + D", hl.dsp.exec_cmd("DICTATION_NOPASTE=1 dictation-toggle"))  -- copy-only
-- recall clipboard/transcript history:
hl.bind(mainMod .. " + V", hl.dsp.exec_cmd(
  "sh -c 'cliphist list | fuzzel --dmenu --with-nth 2 | cliphist decode | wl-copy'"))
```

`SUPER+D` / `SUPER+V` are free. Reload via `hyprctl reload`.

### 5.5 Clipboard history (cliphist)

cliphist is the history layer. Our dictation flow already `wl-copy`s every transcript, so the
`wl-paste --watch cliphist store` watcher (§5.4) **auto-archives every transcript** with no
extra work. Recall via the `SUPER+V` fuzzel picker (`cliphist list` → select → `cliphist
decode | wl-copy`). cliphist does **not** paste — that's still the per-app chord in §5.3;
this is purely history/recall.

- **Config:** `~/.config/cliphist/config` (or `CLIPHIST_MAX_ITEMS` env). Suggest
  `max-items 200`. Text+image+binary supported; add a second `wl-paste --type image --watch
  cliphist store` line if image history is wanted.
- **Wayle bar dropdown (stretch):** a custom Wayle module shells `cliphist list` for the last
  N previews and, on click, runs the same decode→wl-copy pipeline (or just launches the
  fuzzel picker). Exact module shape depends on Wayle's `config.toml` custom-module API —
  verify against `~/.config/wayle/` at implementation. MVP = the `SUPER+V` picker + a bar
  button that launches it.
- Transcripts are **interleaved** with general clipboard items (owner chose a single history,
  no dedicated transcript log). A transcripts-only view can be added later via a separate log.

### 5.6 Dictation provenance marker (consumer side)

The script wraps text in `<dictated_note>…</dictated_note>` for terminal/agent targets
(§5.3, `DICTATION_WRAP=auto|always|never`). For agents to act on it, add the consumer-side
note to **`~/.claude/CLAUDE.md`**:

```md
Text wrapped in <dictated_note>…</dictated_note> is voice-dictated and may contain
transcription errors (homophones, dropped/garbled words). If wording seems odd,
contradictory, or out of place, ask for clarification rather than assuming it was literal.
```

(Also captured as a cross-session memory so it applies even outside tagged input.)

## 6. Verification

1. `getent subuid deuley` non-empty; `loginctl show-user deuley -p Linger` → `Linger=yes`.
2. `podman info --format '{{.Host.OCIRuntime.Name}}'` → `crun`.
3. `systemctl --user status whisper-npu` active; `curl -s 127.0.0.1:8009/models` lists models.
4. `podman logs whisper-server` shows `device='NPU'` (no silent CPU fallback — R3); first
   call 30–60 s, subsequent fast (warm).
5. Headset connected → `pactl set-card-profile <card> headset-head-unit-msbc` →
   `pactl list short sources | grep bluez_input` present; record → `file x.wav` → "RIFF … 16000 Hz".
6. Paste test per class: focus Ghostty → confirm `Ctrl+Shift+V` path; focus Zed/browser →
   `Ctrl+V` path; focus an unlisted app → copy-only notification.
7. **Full loop:** `SUPER+D`, speak, roam windows, `SUPER+D` → clipboard has text (`wl-paste`)
   and it pastes into the focused terminal/editor; trailing newline stripped (no auto-submit).

## 7. Risks

| # | Sev | Risk | Mitigation |
|---|---|---|---|
| R1 | HIGH | Rootless podman has no subuid/subgid today | explicit ranges (§5.1) |
| R2 | **HIGH+** | Upstream repo **archived**; `:latest` mutable | pin digest, `--pull=never`, record model commit, **vendor the Flask server after first proof** |
| R3 | MED | OpenVINO **silently falls back to CPU** | verify `device='NPU'` in logs + first-token latency + container NPU enumeration |
| R4 | MED | HFP profile id varies; A2DP music stops while recording | dual `set-card-profile` fallback; **save & restore previous profile**; source matched by MAC |
| R5 | LOW | Truncated WAV on abnormal stop | SIGINT→poll→TERM; size-stability poll; keep WAV on failure |
| R6 | LOW–MED | Paste chord into wrong/secret surface | clipboard always safe; **paste (not type)** so non-targets ignore it; allow-list of classes; copy-only otherwise; trailing newline stripped |
| R7 | — *fixed* | Detached-process finalization race (`wait` on non-child) | replaced with `kill -0` exit-poll |
| R8 | — *resolved* | NixOS version drift / NPU module availability | already on **26.05**; `npu.enable` present & `true` |

## 8. Remaining open items (low-risk, resolve at bring-up)

1. **Exact window classes** for the paste map — capture each via `hyprctl activewindow -j`
   while focused (the §5.3 list is a sensible starter; ghostty/kitty/Zed/Firefox).
2. **Warm-up call shape** — finalize once `/models` confirms the model-name path; warm with a
   short silent wav so the first real dictation is instant.
3. **Terminal auto-submit** — newline stripped + relying on bracketed paste (Ghostty/Kitty
   support it). Confirm no agent-TUI submits on multiline paste; if one does, gate that class.
4. Whether to add the **`SUPER+Shift+D` copy-only** second bind now or later.

## 9. Process / next steps

1. ✅ Scaffold workspace + write doc (v1).
2. ✅ External review ×2 → **v2 (this doc)** incorporates all consensus fixes.
3. ⏳ Owner go-ahead → implement §5 (`pkgs/dictation/default.nix`, `configuration.nix` via
   `pkexec` rebuild, lua binds + cliphist watcher, `~/.claude/CLAUDE.md` consumer note),
   bring-up §5.2, pin digest, verify §6.
4. After first working proof: **vendor the Flask server** (R2); add the **Wayle bar dropdown**
   (§5.5) and optional 🎙 "recording…" indicator reading the state file.
