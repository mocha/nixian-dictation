# nixian-dictation

Local push-to-talk dictation for NixOS — a self-hosted
[superwhisper](https://superwhisper.com/)-style flow that runs **entirely on your own
hardware**, on an Intel NPU or an NVIDIA GPU.

Press a key → talk (the recorder runs detached, so you can roam between windows) → press
again → [Whisper](https://github.com/openai/whisper) transcribes locally, drops the text on
your clipboard, and pastes it into the focused app.

The transcription server is a small HTTP service. It is loopback-only by default, but it
speaks an OpenAI-compatible route, so it can also be
[opened to other machines](#serving-other-machines) — a laptop, a work Mac — that would
otherwise send your audio to a hosted dictation service.

> **Status:** running on two hosts.
>
> | Host | Engine | Desktop | Speed |
> |---|---|---|---|
> | `nixian` — HP OmniBook X Flip 14, Core Ultra 7 356H ("Panther Lake") | OpenVINO on the Intel NPU (`Intel(R) AI Boost`), `whisper-small.en` | Hyprland | ~0.5 s for a 14 s clip (~23–28× real-time), warm |
> | `dynamo` — RTX 4070 Ti workstation | faster-whisper / CTranslate2 on CUDA, `small.en` fp16 | KDE Plasma | sub-second for a ~13 s clip, warm |
>
> The NPU work came first and is the hard-won part; the GPU backend and the
> `services.dictation` module generalized it to a second machine.

## Why this exists

The obvious off-the-shelf option — the archived `mecattaf/whisper-npu-server` image —
**does not work on Panther Lake**: it bundles OpenVINO 2024.6 + an old NPU driver that
enumerate **CPU only** on the 2026 silicon. Native-on-NixOS is also a dead end today
(nixpkgs `intel-npu-driver` is built without the model compiler). So this repo rebuilds the
NPU inference server against a current, Panther-Lake-capable stack and wires it into a
Hyprland/Wayle desktop.

## How it works

```
key / bar click → dictation-toggle ──START──→ select + configure mic (16 kHz mono)
                                              ├─ pw-record (detached systemd unit) → rec.wav
                                              └─ POST /warm (compile while you talk)
              → dictation-toggle ──STOP───→ SIGINT pw-record, finalize WAV
                                              └─ POST rec.wav → transcription server
                                                 └─ clipboard + per-app paste chord
                                                 └─ cliphist archives it for history

                          ┌─ NPU:  podman container, OpenVINO WhisperPipeline(…, "NPU")
transcription server ─────┤
                          └─ CUDA: systemd --user unit, faster-whisper on the GPU

other machines ──POST /v1/audio/transcriptions──┘   (optional — see below)
```

The server is a small Flask app kept warm by a `systemd --user` service so the model stays
resident (a cold load is slow — ~30 s on the NPU; warm calls are sub-second on both). The
client talks to it over plain HTTP and is backend-agnostic: only the base URL and the model
name differ per host.

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

## Picking a combination

The pieces behind the toggle are swappable. A host declares its combination through the
`services.dictation` NixOS module (`nix/module.nix`) and gets the server + client wired together:

```nix
imports = [ "${dictationSrc}/nix/module.nix" ];

services.dictation = {
  enable  = true;
  desktop = "kde";          # kde (kdotool/dotool) | hyprland (hyprctl/wtype)
  backend = "cuda-local";   # faster-whisper on the GPU
  model   = "small.en";
};
```

| Option | Default | What it picks |
|---|---|---|
| `desktop` | *(required)* | Focused-window detection + paste chord: `hyprland` or `kde` |
| `backend` | `cuda-local` | Transcription engine. `cuda-local` = faster-whisper on the GPU |
| `model` | `small.en` | faster-whisper model id (`small.en`, `distil-large-v3`, `large-v3`, …) |
| `models` | `[ ]` | Extra ids advertised on `/models` |
| `device` / `computeType` | `cuda` / `float16` | CTranslate2 device and precision |
| `port` | `8009` | TCP port the server binds and the client posts to |
| `bind` | `127.0.0.1` | Address the server binds — see [Serving other machines](#serving-other-machines) |
| `openFirewall` | `false` | Open `port` in the system firewall |
| `tray` | `true` | AppIndicator/SNI status daemon |
| `wrap` | `auto` | `<dictation>` provenance wrapping around pasted text |

The **NPU backend** (`npu-image/`, OpenVINO on an Intel NPU) predates the module and is still wired
up imperatively on `nixian` — see [PROJECT.md](PROJECT.md). Both backends speak the same HTTP
contract, so `dictation-toggle` does not know or care which is answering.

## The HTTP contract

Both backends serve the same routes, so a client written against one works against the other:

| Route | Body | Returns |
|---|---|---|
| `GET /health` | — | `{requested_device, available_devices, loaded, default}` |
| `GET /models` | — | `{models: [...]}` |
| `POST /warm[/<model>]` | — | `{warm, model}` — force the (slow, cold) model load early |
| `POST /transcribe[/<model>]` | raw audio | `{text}` |
| `POST /v1/audio/transcriptions` | multipart `file` | OpenAI-shaped `{text}` |
| `POST /audio/transcriptions` | multipart `file` | the same, for clients whose base URL ends in `/v1` |

`/v1/audio/transcriptions` is the OpenAI-compatible one: it takes multipart `file`, plus optional
`model` and `response_format` (`json` | `text` | `verbose_json`). An unknown `model` — including
OpenAI's own `whisper-1` — falls back to the server default, so clients that insist on naming a
hosted model still work.

## Serving other machines

By default the server binds loopback and only this host's toggle can reach it. Point another
machine's dictation client at this box's GPU instead of a hosted transcription service:

```nix
services.dictation = {
  bind         = "*";     # every interface, IPv4 and IPv6
  openFirewall = true;    # opens `port` (both families)
};
```

Then give the client `http://<host>:8009` as an OpenAI-compatible base URL. Verify from the other
machine before touching the client's settings:

```bash
curl http://<host>:8009/health
curl -F "file=@sample.wav" -F "model=whisper-1" \
     http://<host>:8009/v1/audio/transcriptions
```

**This endpoint has no authentication.** Anyone who can reach the port can spend your GPU on their
audio and read the transcript back, so the network you expose it to is the entire trust boundary.
Keep it to a LAN you control and never port-forward it. If you need it from elsewhere, put it on a
tailnet or an SSH tunnel (`ssh -L 8009:127.0.0.1:8009 <host>`) rather than widening `bind`.

### Gotchas when a client can't connect

- **Use `bind = "*"`, not `"0.0.0.0"`, if clients connect by hostname.** `0.0.0.0` is IPv4-only. A
  `.lan` name that also resolves to an AAAA record sends any happy-eyeballs client (Electron apps,
  browsers) to an IPv6 address nothing is listening on. The client reports a refused connection or
  an invalid URL — never anything mentioning IPv6 — and `curl` hides it by falling back to IPv4.
  Reproduce with `curl -6 http://<host>:8009/health`, which fails while the plain form succeeds.
- **Try the base URL both with and without `/v1`.** Clients disagree about whether the base already
  includes it. Both spellings are registered, so this should not bite, but it is the first thing to
  check against a client this repo hasn't met.
- **A 404 names itself.** Unmatched requests are logged with the path and the full route table:
  `journalctl --user -u dictation-whisper -n 20`.

## Repo layout

| Path | What |
|---|---|
| `nix/module.nix` | the `services.dictation` NixOS module — where a host picks its combination |
| `nix/package.nix` | builds `dictation-toggle` for the chosen desktop, defaults baked in |
| `nix/whisper-env.nix` | faster-whisper + CUDA env, scoped so only ctranslate2 rebuilds |
| `nix/tray.nix` | packages the tray daemon |
| `backends/cuda/server.py` | the `cuda-local` transcription server (faster-whisper / CTranslate2) |
| `lib/desktop-kde.sh`, `lib/desktop-hyprland.sh` | per-desktop focus detection + paste chord |
| `tray/dictation-tray.py` | AppIndicator/SNI status + control daemon |
| `npu-image/Dockerfile` | builds the Panther-Lake NPU Whisper image |
| `npu-image/server.py` | the NPU transcription server (vendored + hardened from upstream) |
| `dictation-toggle.sh` | the record→transcribe→paste toggle (body for `writeShellApplication`) |
| `default.nix` | packages `dictation-toggle` with its runtime deps |
| `integration/dictation-status.sh` | bar-module state reporter (down/idle/recording) |
| `PROJECT.md` | the full design + build log + every gotcha (read this for detail) |

## Setup

For a GPU host, the module above is the whole setup — `services.dictation` builds the client,
runs the server as a `systemd --user` unit, and fetches the model on first use.

### The NPU path (high level — see `PROJECT.md` for the full walkthrough)

Not yet wired into the module; `nixian` still runs this imperatively.


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

Mostly `nixian` (NPU + Hyprland) findings. The networking ones live under
[Serving other machines](#serving-other-machines).

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
