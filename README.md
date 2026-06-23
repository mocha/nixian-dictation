# nixian-dictation

Local, NPU-accelerated push-to-talk dictation for NixOS + Hyprland — a self-hosted
[superwhisper](https://superwhisper.com/)-style flow that runs **entirely offline on the
Intel NPU**.

Press a key → talk (the recorder runs detached, so you can roam between windows) → press
again → [Whisper](https://github.com/openai/whisper) transcribes on the NPU, drops the text
on your clipboard, and pastes it into the focused app.

> **Status:** working end-to-end on an HP OmniBook X Flip 14 (Intel Core Ultra 7 356H,
> "Panther Lake"). Transcription runs on the NPU (`Intel(R) AI Boost`) at **~0.5 s for a
> 14 s clip (~23–28× real-time)** once the model is warm.

## Why this exists

The obvious off-the-shelf option — the archived `mecattaf/whisper-npu-server` image —
**does not work on Panther Lake**: it bundles OpenVINO 2024.6 + an old NPU driver that
enumerate **CPU only** on the 2026 silicon. Native-on-NixOS is also a dead end today
(nixpkgs `intel-npu-driver` is built without the model compiler). So this repo rebuilds the
NPU inference server against a current, Panther-Lake-capable stack and wires it into a
Hyprland/Wayle desktop.

## How it works

```
key / bar click → dictation-toggle ──START──→ force BT mic to HFP/mSBC (16 kHz mono)
                                              └─ pw-record (detached systemd unit) → rec.wav
              → dictation-toggle ──STOP───→ SIGINT pw-record, finalize WAV
                                              └─ POST raw WAV → whisper server (NPU)
                                                 └─ wl-copy + per-app paste chord
                                                 └─ cliphist archives it for history

whisper server = rootless-podman container, kept warm by a systemd --user service so the
model stays resident on the NPU (cold load is ~30 s; warm calls are sub-second).
```

The transcription engine is a small Flask server (`npu-image/server.py`) running
`openvino_genai.WhisperPipeline(model, "NPU", STATIC_PIPELINE=True)`.

## The working NPU stack (the hard-won part)

| Piece | Pin | Note |
|---|---|---|
| Base image | `ubuntu:24.04` | |
| NPU driver (UMD + compiler) | **intel/linux-npu-driver v1.28.0** | first release with Panther Lake support |
| level-zero **loader** | **oneapi-src v1.30.0** (`libze1`) | **the key fix** — Ubuntu's bundled `libze1` 1.16 is too old to load the 1.28 driver, so the NPU won't enumerate |
| OpenVINO + GenAI | **2026.2.1** | `WhisperPipeline(..., "NPU", STATIC_PIPELINE=True)` |
| Model | **`OpenVINO/whisper-small.en-fp16-ov`** | 2024-era IR fails the static NPU pipeline (`self_attn_nodes.empty()`); use a current OpenVINO export |

Host needs the in-kernel `intel_vpu` driver + `vpu_50xx` firmware (mainline Linux ≥ 6.13 /
recent `linux-firmware`), and `/dev/accel/accel0` + `/dev/dri` passed into the container.

## Repo layout

| Path | What |
|---|---|
| `npu-image/Dockerfile` | builds the Panther-Lake NPU Whisper image |
| `npu-image/server.py` | the transcription server (vendored + hardened from upstream) |
| `dictation-toggle.sh` | the record→transcribe→paste toggle (body for `writeShellApplication`) |
| `default.nix` | packages `dictation-toggle` with its runtime deps |
| `integration/dictation-status.sh` | bar-module state reporter (down/idle/recording) |
| `PROJECT.md` | the full design + build log + every gotcha (read this for detail) |

## Setup (high level — see `PROJECT.md` for the full walkthrough)

1. **Build the image:** `cd npu-image && podman build -t whisper-npu-ptl:local .`
2. **Fetch the model:** `git clone https://huggingface.co/OpenVINO/whisper-small.en-fp16-ov ~/.whisper/models/whisper-small.en-fp16-ov` (with git-lfs).
3. **Verify NPU:** run the image with `--device=/dev/accel/accel0 --device=/dev/dri … python3 -c "import openvino; print(openvino.Core().available_devices)"` → expect `['CPU', 'NPU']`.
4. **NixOS:** add `virtualisation.podman.enable`, subuid/subgid + `linger` for your user, the `dictation` package (`callPackage ./pkgs/dictation {}`), and a `systemd.user.services.whisper-npu` that runs the container with the model mounted and bound to `127.0.0.1:8009`. Add `wtype`, `cliphist`, `fuzzel`.
5. **Hyprland bind** (lua config):
   ```lua
   hl.bind("SUPER + SHIFT + F23", hl.dsp.exec_cmd("dictation-toggle"))  -- HP Assistant button
   ```
6. **Wayle bar module** — a `custom-dictation` module pointing `command`/`on-action` at
   `integration/dictation-status.sh` and `left-click` at `dictation-toggle`.

## Gotchas worth knowing

- **Mic = Bluetooth.** On this hardware the internal mic is dead (Panther Lake SoundWire
  firmware gap), so the script targets the BT headset's HFP/mSBC source. Sony multipoint
  headsets drop their audio link intermittently — the most common "it didn't work."
- **The HP Assistant/Copilot button is `SUPER + SHIFT + F23`.** `wev` *displays*
  `XF86Assistant`, but that's the shifted level — Hyprland matches the **base keysym `F23`**.
  Binding `XF86Assistant` silently never fires.
- **`wl-copy` daemonizes and will inherit (and hold forever) a `flock` fd** — close it with
  `wl-copy 9>&-` or your single-instance lock wedges after the first run.
- **NPU needs the static Whisper pipeline + a current model export.** Old IR fails to compile.

## Credits

The transcription server and Docker approach derive from
[mecattaf/whisper-npu-server](https://github.com/mecattaf/whisper-npu-server) (MIT), itself a
fork of [ellenhp/whisper-npu-server](https://github.com/ellenhp/whisper-npu-server) (MIT).
Both are archived; this repo rebuilds the stack for Panther Lake. Models from the
[OpenVINO](https://huggingface.co/OpenVINO) HuggingFace org.

## License

MIT — see [LICENSE](LICENSE).
