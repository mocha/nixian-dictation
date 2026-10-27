# TODO

- **nixian unit:** bind-mount the archive and set the timezone in `systemd.user.services.whisper-npu`
  (`/etc/nixos/configuration.nix`); mount `%h/Recordings/Dictation` → `/root/Recordings/Dictation` and pass `-e TZ=…`.
- **dynamo deploy:** pull + `nixos-rebuild` to pick up two-speaker detection and the server archive on the
  CUDA backend; drop `~/.config/dictation/voices.json` there (or set `services.dictation.voices`).
- **dynamo archive → NAS:** dynamo has no prune/backup timers, so its archive never reaches the NAS.
- **Evaluate moving the server to mothership** (homelab, weak GPU) so API clients keep working while dynamo
  is booted into Windows. Nixian stays on its local NPU regardless (offline use).
- Optional: ffmpeg in the NPU image so m4a/webm uploads decode there (they're archived but fail today).
