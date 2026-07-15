# Back-compat entry point. The real packaging now lives in nix/ (seam-based, per-host):
#   - nix/package.nix  — the dictation-toggle client (parameterized by desktop/model/…)
#   - nix/module.nix   — services.dictation (server + client + tray), the preferred integration
#   - nix/tray.nix     — the AppIndicator/SNI status daemon
#
# This default builds the hyprland (Nixian) client, preserving the old `callPackage ./. {}`
# interface. New consumers should import nix/module.nix instead. See README.md / PROJECT.md.
{ callPackage }:
callPackage ./nix/package.nix { desktop = "hyprland"; }
