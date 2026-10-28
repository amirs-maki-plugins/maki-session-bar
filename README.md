# maki-session-bar

A session title bar for [maki](https://github.com/tontinton/maki): a
`[session-name]` block on the lower line of the input box border, plus a
per-session color that paints the name block and the border together.

```
────────[ my refactoring ]────────
```

## What it does

- Shows the focused session's title, truncated to 30 display cells.
- `/color [color]` sets the color of the name block and the input box border
  together. No argument opens a picker built from the theme's own palette.
  `default` or `reset` restores the theme's colors.
- The color is remembered per session id in
  `~/.local/state/maki/session_colors.json`, so a session restored after a
  restart comes back with the color it left with.
- The terminal window title follows the session name and cwd.

## Install

Declare it in your global `init.lua` (`~/.config/maki/init.lua`), then
restart maki and accept the install prompt:

```lua
maki.pack.add({
  { src = "https://github.com/amirs-maki-plugins/maki-session-bar" },
})
```

## Requirements

- maki 0.6.5 or newer (`SessionCwdChanged`).
- The `/color` picker and the theme-matched name color read the running
  theme through `maki.ui.get_theme_color` and `maki.ui.get_theme_palette`.
  Those exist in the `feat/theme-color` branch of
  [amirfr3/maki](https://github.com/amirfr3/maki) and are proposed upstream
  in its pull request. On a build without them the bar still works, with
  the theme's own border color and the built-in swatch list.

## Specs

The pure helpers are covered by `/spec`:

```
maki /spec session_bar_spec
maki /spec swatches_spec
```
