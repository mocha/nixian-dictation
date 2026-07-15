# KDE Plasma (KWin Wayland) desktop adapter — the two desktop-specific operations
# dictation-toggle needs. Inlined into the script at build time by nix/package.nix (replacing the
# adapter marker); no shebang / no `set` here on purpose.
#
# KWin (unlike wlroots) doesn't drive wtype's virtual-keyboard protocol reliably, and there's no
# `hyprctl`. So: focused-window class via kdotool (a KWin-scripting xdotool clone), and paste
# chord via dotool (synthesizes through /dev/uinput, which a normal Plasma login can already
# write to via logind's uaccess ACL — verified: `user:deuley:rw-` on /dev/uinput, no extra group).

# Print the class of the currently-focused window (empty if none / not determinable). kdotool
# returns the same class strings hyprctl does on this hardware (e.g. com.mitchellh.ghostty), so
# the caller's is_terminal()/paste-map need no per-desktop changes.
desktop_active_class() {
  kdotool getactivewindow getwindowclassname 2>/dev/null
}

# Synthesize the focused app's paste chord via uinput. kind=terminal -> Ctrl+Shift+V, else
# Ctrl+V. dotool reads commands on stdin; DOTOOL_DELAY (ms, default in dotool) gives the
# compositor a beat to notice the freshly-created virtual device before the chord — without it a
# one-shot dotool can drop the first event. If this proves flaky in practice, switch to the
# dotoold/dotoolc daemon (persistent virtual device, added as a systemd --user service).
desktop_paste() {
  local kind="$1"
  if [ "$kind" = "terminal" ]; then
    printf 'key ctrl+shift+v\n' | dotool 2>/dev/null
  else
    printf 'key ctrl+v\n' | dotool 2>/dev/null
  fi
}
