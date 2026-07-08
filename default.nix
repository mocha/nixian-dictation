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
, playerctl       # pause/resume media (MPRIS) around recording
, hyprland        # hyprctl
, util-linux      # flock
, systemd         # systemctl / systemd-run
, coreutils       # stat, cat, seq, mkdir, printf
, gnused          # sed
, gawk            # awk
, sox             # opt-in auto-stop recorder (records-until-trailing-silence via the `silence` effect)
, sound-theme-freedesktop   # start/stop chime sounds (.oga), played via pw-play
}:

writeShellApplication {
  name = "dictation-toggle";
  runtimeInputs = [
    pipewire wl-clipboard wtype jq curl libnotify
    pulseaudio playerctl hyprland util-linux systemd coreutils gnused gawk sox
  ];
  # Bake the sound-theme store path into the script (the @SOUNDS@ placeholder) so the chimes are
  # hermetic — pw-play (from pipewire, already on PATH) reads the .oga files directly.
  text = builtins.replaceStrings
    [ "@SOUNDS@" ]
    [ "${sound-theme-freedesktop}/share/sounds/freedesktop/stereo" ]
    (builtins.readFile ./dictation-toggle.sh);
}
