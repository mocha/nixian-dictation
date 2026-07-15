# Packages `dictation-toggle` with all runtime deps on PATH and the per-host desktop adapter
# (lib/desktop-<desktop>.sh) inlined in place of the `# @DESKTOP_LIB@` marker. writeShellApplication
# runs shellcheck on the *substituted* text at build time, so both the body and the inlined adapter
# must stay lint-clean.
#
#   pkgs.callPackage ./nix/package.nix { desktop = "kde"; }      # Dynamo (KWin: kdotool + dotool)
#   pkgs.callPackage ./nix/package.nix { desktop = "hyprland"; } # Nixian (wlroots: hyprctl + wtype)
{ lib
, writeShellApplication
, pipewire        # pw-record / pw-play
, wl-clipboard    # wl-copy
, jq
, curl
, libnotify       # notify-send
, pulseaudio      # pactl (talks to pipewire-pulse; used for BT card/source management)
, playerctl       # pause/resume MPRIS media around recording
, util-linux      # flock
, systemd         # systemctl / systemd-run
, coreutils
, gnused
, gawk
, sox             # opt-in auto-stop + streaming segment slicing
# desktop-specific — only the selected set is added to PATH:
, hyprland        # hyprctl        (desktop = hyprland)
, wtype           # paste chord    (desktop = hyprland)
, kdotool         # active window  (desktop = kde)
, dotool          # paste chord    (desktop = kde)
, desktop ? "hyprland"   # "hyprland" | "kde"
# Per-host server defaults baked into the client (all overridable at runtime via DICTATION_*):
, model ? "whisper-small.en-fp16-ov"   # default transcription model name
, serverUnit ? "whisper-npu"           # systemd --user unit the client checks is running
, port ? 8009                          # server port (client + server must agree)
, wrapMode ? "auto"                    # <dictation> provenance wrap default: auto | always | never
}:
let
  desktopInputs = {
    hyprland = [ hyprland wtype ];
    kde = [ kdotool dotool ];
  }.${desktop} or (throw "dictation: unknown desktop '${desktop}' (expected 'hyprland' or 'kde')");
  desktopLib = builtins.readFile (../lib + "/desktop-${desktop}.sh");
in
writeShellApplication {
  name = "dictation-toggle";
  runtimeInputs = [
    pipewire wl-clipboard jq curl libnotify
    pulseaudio playerctl util-linux systemd coreutils gnused gawk sox
  ] ++ desktopInputs;
  # Bake the notification-chime dir (@SOUNDS@ -> the bundled ./sounds, copied to the store) and the
  # desktop adapter (# @DESKTOP_LIB@) in, so the result is hermetic and self-contained (single
  # script, no runtime `source`). The chimes are personally licensed (noncommercial) — see ../sounds.
  text = builtins.replaceStrings
    [ "@SOUNDS@" "# @DESKTOP_LIB@" "@MODEL@" "@SERVER_UNIT@" "@PORT@" "@WRAP@" ]
    [ "${../sounds}" desktopLib model serverUnit (toString port) wrapMode ]
    (builtins.readFile ../dictation-toggle.sh);
}
