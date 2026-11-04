# maki-session-bar

A session title bar for [maki](https://github.com/tontinton/maki): a
`[session-name]` block on the lower line of the input box border, plus a
per-session color that paints the name block and the border together.

```
────────────────[ my refactoring ]
```

The block is the whole window. The rule it sits on is the host's, so it
keeps the theme's own color and the mode tint, and the bar's window is
only as wide as the label.

## What it does

- Shows the focused session's title, truncated to 30 display cells.
- `/color [color]` sets the color of the name block and the input box border
  together. No argument opens a picker built from the theme's own palette.
  `default` or `reset` restores the theme's colors.
- While the agent works, the rule fades toward the theme's background and
  comes back when the turn ends. The name block keeps its color.
- The color is remembered per session id in
  `~/.local/state/maki/session_colors.json`, so a session restored after a
  restart comes back with the color it left with.
- While subagents or background tasks of the session run, a spinner and
  their count follow the title: `[my refactoring] ⠋ 2`.
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

- maki 0.7.0 or newer (`SessionCwdChanged`, session-scoped windows).
- The border repaint needs `maki.ui.set_theme_style`. Without it the plugin
  does not register `/color` at all, and the bar still shows the title with
  the theme's own border.
- The picker reads the running palette through `maki.ui.get_theme_palette`,
  and the fade needs `maki.ui.theme_color("background")`. Without them the
  picker falls back to the built-in swatches, and the fade falls back to the
  terminal's dim attribute.

## Specs

The pure helpers are covered by `/spec`:

```
maki /spec session_bar_spec
maki /spec swatches_spec
```
