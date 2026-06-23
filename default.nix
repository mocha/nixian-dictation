# Packages `dictation-toggle` with all runtime deps on PATH (no reliance on "already
# present" tools). writeShellApplication runs shellcheck at build time, so the body in
# dictation-toggle.sh must stay lint-clean.
#
# Installed into /etc/nixos/pkgs/dictation/ and referenced from configuration.nix as:
#   (callPackage ./pkgs/dictation { })
{ writeShellApplication
, pipewire        # pw-record
, wl-clipboard    # wl-copy
, wtype           # paste chord
, jq
, curl
, libnotify       # notify-send
, pulseaudio      # pactl
, hyprland        # hyprctl
, util-linux      # flock
, systemd         # systemctl / systemd-run
, coreutils       # stat, cat, seq, mkdir, printf
, gnused          # sed
, gawk            # awk
}:

writeShellApplication {
  name = "dictation-toggle";
  runtimeInputs = [
    pipewire wl-clipboard wtype jq curl libnotify
    pulseaudio hyprland util-linux systemd coreutils gnused gawk
  ];
  text = builtins.readFile ./dictation-toggle.sh;
}
