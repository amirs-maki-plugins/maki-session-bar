-- session_bar_spec: pure-helper cases for the session_bar plugin.
-- Run with /spec. No window is opened; only the helpers run.

local sb = require("session_bar")
local t = sb._test

local cases = {}

cases.readable_fg_luminance = function(check)
  check.eq(t.readable_fg("#ffffff"), "#101010", "white bg -> dark ink")
  check.eq(t.readable_fg("#000000"), "#f0f0f0", "black bg -> light ink")
  check.eq(t.readable_fg("#7f7f7f"), "#f0f0f0", "luminance 127 stays light ink")
  check.eq(t.readable_fg("#808080"), "#101010", "luminance 128 flips to dark ink")
  check.eq(t.readable_fg("#7fffff"), "#101010", "bright cyan bg -> dark ink")
  check.eq(t.readable_fg("default"), "default")
  check.eq(t.readable_fg("blue"), "default", "a non-hex name defers to the theme")
end

cases.short_title_truncates_with_ellipsis = function(check)
  check.eq(t.short_title("short", 15), "short")
  check.eq(t.short_title("exactly-15-chars!", 15), "exactly-15-cha…",
    "16 chars cut to 14 cells + ellipsis = 15")
  local long = string.rep("a", 40)
  local cut = t.short_title(long, 15)
  check.eq(#cut, 17, "14 ascii bytes + the 3-byte ellipsis")
  check.eq(cut:sub(15), "…")
end

cases.short_title_wide_runes = function(check)
  -- "█" is one cell, "…"-safe cut; emoji are wide: cut before overrun
  local emoji = "🎉🎉🎉🎉"
  local cut = t.short_title(emoji, 5)
  check.eq(cut, "🎉🎉…", "wide runes cut at the cell budget, not the byte count")
end

cases.mac_short_collapses_parents = function(check)
  check.eq(t.mac_short("/Users/amir/Documents/inference/vllm"), "/U/a/D/i/vllm")
  check.eq(t.mac_short("/Users/amir"), "/U/amir")
  check.eq(t.mac_short("/"), "/")
  check.eq(t.mac_short("/single"), "/single", "one component is untouched")
end

cases.win_title_composition_without_cwd = function(check)
  check.eq(t.win_title("t", nil), "t (maki)")
  check.eq(t.win_title(nil, nil), "maki")
end

cases.win_title_composition_with_cwd = function(check)
  check.eq(t.win_title("t", "~/D/i/vllm"), "t - ~/D/i/vllm (maki)")
  check.eq(t.win_title(nil, "/tmp"), "maki - /tmp")
end

cases.short_cwd_shortens_under_home = function(check)
  local home = (maki.uv and maki.uv.os_homedir and maki.uv.os_homedir()) or "/home/x"
  check.eq(t.short_cwd("/"), "/")
  check.eq(t.short_cwd(""), nil, "empty cwd is no cwd")
  check.eq(t.short_cwd(nil), nil)
  check.eq(t.short_cwd(home), "~", "home itself collapses to ~")
  check.eq(t.short_cwd(home .. "/Documents"), "~/Documents",
    "a single component under home stays whole")
  check.eq(t.short_cwd(home .. "/Documents/inference"), "~/D/inference",
    "parents keep their first letter")
end

cases.canonical_color_names_hex_default = function(check)
  check.eq(t.valid_color("default"), "default")
  check.eq(t.valid_color("red"):match("^#%x%x%x%x%x%x$") ~= nil, true,
    "a swatch name resolves to a hex (the theme may override the default)")
  check.eq(t.valid_color("#ff0000"), "#ff0000", "a hex the picker hands over passes through")
  check.eq(t.valid_color("mauve"), nil, "a non-swatch name is rejected")
  check.eq(t.valid_color(""), nil)
  check.eq(t.valid_color(nil), nil)
end

cases.valid_saved_color_hex_or_default = function(check)
  check.eq(t.valid_saved_color("#ff8800"), true)
  check.eq(t.valid_saved_color("default"), true)
  check.eq(t.valid_saved_color("#ff880"), false, "5 digits")
  check.eq(t.valid_saved_color("red"), false, "names are never stored, hex is")
  check.eq(t.valid_saved_color(42), false)
  check.eq(t.valid_saved_color(nil), false)
end

cases.sanitize_colors_drops_bad_entries = function(check)
  local clean = t.sanitize_colors({
    ["abc"] = "#ff8800",
    ["def"] = "red",
    [""] = "#ffffff",
    ["ghi"] = 7,
    [8] = "#ffffff",
  })
  check.eq(clean["abc"], "#ff8800")
  check.eq(clean["def"], nil, "a non-hex value is dropped")
  check.eq(clean[""], nil, "an empty sid is dropped")
  check.eq(clean["ghi"], nil, "a non-string value is dropped")
  check.eq(clean[8], nil, "a numeric sid is dropped")
  check.eq(t.sanitize_colors("junk")["abc"], nil, "a non-table decodes to nothing")
end

return { cases = cases, name = "session_bar" }
