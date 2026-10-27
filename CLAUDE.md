# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Local, NPU-accelerated push-to-talk dictation for NixOS + Hyprland on an HP OmniBook X Flip 14
(Intel Core Ultra 7 356H, "Panther Lake"). Press a key → talk → press again → Whisper transcribes
**entirely offline on the Intel NPU**, copies the text, and pastes it into the focused app.
Everything runs on this one machine; there is no cloud ASR and no CI.

`PROJECT.md` is the exhaustive design + build log + every hardware gotcha — read it for detail on
*why* a given pin or workaround exists. `README.md` is the public-facing summary. This file is the
orientation for making changes.

## Two independent halves

1. **The NPU server** (`npu-image/`) — a small Flask app (`server.py`) wrapping
   `openvino_genai.WhisperPipeline(model, "NPU", STATIC_PIPELINE=True)`, packaged as a rootless-podman
   image and kept warm by a `systemd --user` service (`whisper-npu`). Listens on `127.0.0.1:8009`
   (host) → `5000` (container). Models live in `~/.whisper/models` (bind-mounted).
2. **The toggle client** (`dictation-toggle.sh`) — the record→transcribe→paste shell flow, packaged
   by `default.nix` and bound to a key in Hyprland. `integration/dictation-status.sh` is the bar-icon
   state reporter.

The two only ever talk over HTTP on `127.0.0.1:8009`. The server contract:
`POST /transcribe/<model>[?speakers=auto|off]` with a **raw** WAV body → `{"text":..., "mode":"mono"|"dual"}`
| `{"error":...}`. A stereo body whose channels carry two different speakers (one lav per channel,
detected in `npu-image/dual.py`) yields `mode:"dual"`, a `segments` list, and `text` as
`[m:ss][A] ...` lines merged by time; anything else is downmixed and transcribed as before. Also
`POST /warm[/<model>]` (force cold-compile, no audio), `GET /health`, `GET /models`, and an
OpenAI-compatible `POST /v1/audio/transcriptions` (multipart), which applies the same two-speaker
detection (form field `speakers=off` to disable; `verbose_json` adds `segments`). Detection is driven
purely by the uploaded audio, so any client that sends a stereo two-lav recording gets it.
A/B become names when `~/.whisper/models/voices.json` (`{"Name": median_pitch_hz}`, read per
request, no rebuild) matches the two channels by pitch; otherwise they stay A/B.

Both backends (`npu-image/server.py` on nixian, `backends/cuda/server.py` on dynamo) share
`backends/common/`: `dual.py` (two-speaker detection/segmentation/naming) and `archive.py` (every
request saved as audio-as-uploaded + `.txt` + `.json` under `WHISPER_ARCHIVE_DIR`, default
`~/Recordings/Dictation`, `off` disables; per-request `archive=0`). The toggle client archives its
own recordings and sends `archive=0`, so server archiving effectively covers API callers (OpenWhispr).
Nixian stays on its local NPU — offline operation on the laptop is a hard requirement.

## Commands

Server image:
```sh
podman build -t whisper-npu-ptl:local -f npu-image/Dockerfile .   # from the REPO ROOT (needs backends/common)
systemctl --user restart whisper-npu     # after any server.py or image change (see below)
systemctl --user status whisper-npu
podman logs whisper-server               # must show device='NPU' — a CPU-only fallback is a bug
```

Poke the server directly:
```sh
curl -s 127.0.0.1:8009/health            # {available_devices:[CPU,NPU], loaded, default, ...}
curl -s 127.0.0.1:8009/models
curl -s -X POST 127.0.0.1:8009/warm/whisper-small.en-fp16-ov
curl -s -H 'Content-Type: audio/wav' --data-binary @clip.wav \
     -X POST 127.0.0.1:8009/transcribe/whisper-small.en-fp16-ov
```
`npu-image/courtroom.wav` is a handy real-speech test clip. The server decodes via `librosa`, so
non-WAV inputs need converting first (there is **no ffmpeg on this host** — get it via
`nix-shell -p ffmpeg`).

Client script: it is validated by `shellcheck` at Nix build time (`writeShellApplication`), so it
must stay lint-clean. Build/apply happens through the machine's NixOS config (a `pkexec nixos-rebuild`),
not from this repo — this repo is where the script is authored and iterated.

## Things that will bite you

- **`server.py` is `COPY`'d into the image, not bind-mounted.** Editing it does nothing until you
  `podman build` **and** `systemctl --user restart whisper-npu`. Same for `backends/common/*.py` and the `Dockerfile`.
  The container's `/root/Recordings/Dictation` must be bind-mounted, or server archives vanish with it.
- **`dictation-toggle.sh` is a script *body*, not a standalone script.** `writeShellApplication`
  (in `default.nix`) prepends the shebang, the `runtimeInputs` PATH, and `set -euo pipefail`. Do
  **not** add a shebang or `set` line — it breaks the shellcheck build. Every external tool the
  script calls must be declared in `runtimeInputs`; nothing is assumed "already on PATH".
- **`@SOUNDS@` is a build-time placeholder** substituted by `default.nix` with the
  `sound-theme-freedesktop` store path. It is literal text in the `.sh` — don't "fix" it.
- **The NPU stack versions are mutually load-bearing and pinned for a reason** (Dockerfile): NPU
  driver **v1.28.0** (first Panther Lake release) + level-zero loader **v1.30.0** (Ubuntu's bundled
  1.16 is too old to load 1.28 → NPU silently enumerates CPU-only) + OpenVINO/GenAI **2026.2.1** +
  a **current** OpenVINO model export (2024-era IR fails the static NPU pipeline). Bumping any one
  without the others is how you get a silent CPU fallback or a compile failure.
- **The internal mic is dead** (Panther Lake SoundWire/SOF gap) — any `*sof_sdw*` source is rejected
  on purpose. The real mic is a Bluetooth headset; the START path steals its A2DP link for an
  HFP/mSBC (16 kHz mono) source, matched to the card by normalized MAC, and restores the profile on
  STOP. If there's no BT device it falls back to the default PipeWire source.

## Client control flow (`dictation-toggle.sh`)

One entrypoint, dispatched by state, guarded by a single-instance `flock` on fd 9:
- **STOP** (recording unit active) → stop the transient unit (SIGINT finalizes the WAV) → `finalize()`.
- **START** (nothing active) → force BT HFP mic → record via `pw-record` inside a **transient
  `systemd --user` unit** (`dictation-rec`) so it survives this process exiting → confirm the unit is
  *really* active (it reads "active" the instant `pw-record` forks, before it can fail to bind the
  node — hence the settle-and-recheck) → fire a detached `/warm` so a cold NPU compiles while you
  talk → persistent "Recording…" notification.
- **`__watch`** (internal, re-execs `$0 __watch`, detached) → only spawned for the opt-in **streaming**
  (`DICTATION_STREAM=1`, transcribe segments live for near-instant paste) or **auto-stop**
  (`DICTATION_AUTOSTOP_SILENCE`) modes; it polls the growing WAV's tail and owns `finalize()`.

`finalize()` is the shared tail: restore BT profile, resume paused media, archive the WAV+transcript
to `~/Recordings/Dictation`, POST to the server (or use the stitched streaming text), then `deliver()`
— `wl-copy` then synthesize the focused app's own paste chord (`Ctrl+Shift+V` for terminals,
`Ctrl+V` for a known allow-list, copy-only otherwise). Terminal/agent targets get the text wrapped in
`<dictation>…</dictation>` provenance markers.

Two `wl-copy`/daemon fd hazards to preserve: **always close fd 9 (`9>&-`) when spawning a
daemonizing child** (`wl-copy`, detached `curl`, the `__watch` re-exec) — otherwise it inherits the
`flock` and wedges every subsequent run. Recording has **no time cap by default** because unit expiry
would kill the recorder without running the STOP/transcribe branch (audio lost).
