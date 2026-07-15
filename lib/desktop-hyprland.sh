# Hyprland (wlroots) desktop adapter — the two desktop-specific operations dictation-toggle
# needs. Inlined into the script at build time by nix/package.nix (replacing the adapter marker);
# no shebang / no `set` here on purpose (it's spliced into a body that already has them).
#
# Focused-window class via hyprctl; paste chord via wtype (virtual-keyboard protocol, which
# wlroots implements). This is the original Nixian path, unchanged.

# Print the class of the currently-focused window (empty if none / not determinable).
desktop_active_class() {
  hyprctl activewindow -j 2>/dev/null | jq -r '.class // empty'
}

# Synthesize the focused app's paste chord. kind=terminal -> Ctrl+Shift+V (terminals' paste),
# anything else -> Ctrl+V. Returns non-zero if the injection failed (caller falls back to
# "copied, paste manually").
desktop_paste() {
  local kind="$1"
  if [ "$kind" = "terminal" ]; then
    wtype -M ctrl -M shift -k v -m shift -m ctrl 2>/dev/null
  else
    wtype -M ctrl -k v -m ctrl 2>/dev/null
  fi
}
