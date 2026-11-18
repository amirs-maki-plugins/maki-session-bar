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

cases.fade_keeps_a_hex_a_hex = function(check)
  local faded = t.fade("#ff0000")
  check.eq(faded.fg:match("^#%x%x%x%x%x%x$") ~= nil, true, "still a hex color")
end

cases.fade_of_a_name_asks_the_terminal_to_dim = function(check)
  -- A palette or ANSI name has no RGB to blend, whatever the theme's
  -- background is, so the fallback is deterministic.
  local faded = t.fade("blue")
  check.eq(faded.fg, "blue", "the name stays as it is")
  check.eq(faded.dim, true, "a name has no RGB to blend")
end

cases.label_width_counts_a_trailing_cell = function(check)
  check.eq(t.label_width("[abc]"), 6, "5 cells plus the separating blank")
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

cases.filter_rows_matches_every_word_in_any_order = function(check)
  local rows = { { label = "default (theme)" }, { label = "violet/magenta" }, { label = "green" } }
  check.eq(#t.filter_rows(rows, ""), 3, "an empty query keeps every row")
  check.eq(#t.filter_rows(rows, "magenta violet"), 1, "words match in any order")
  check.eq(t.filter_rows(rows, "violet")[1].label, "violet/magenta")
  check.eq(#t.filter_rows(rows, "mauve"), 0, "a word no row has leaves nothing")
  check.eq(#t.filter_rows(rows, "the"), 1, "a match inside the label counts")
end

cases.color_row_paints_the_selected_row_in_its_own_color = function(check)
  local row = { label = "red", value = "#ff0000", hex = "#ff0000" }
  local width = 30
  local selected = t.color_row(row, true, width, "#202020")
  check.eq(selected[1][2].fg, "#ff0000", "the label wears the swatch color")
  check.eq(selected[1][2].bg, "#202020", "over the selection background")
  local unselected = t.color_row(row, false, width, "#202020")
  check.eq(unselected[1][2], "item", "an unselected label stays an ordinary row")

  local w = 0
  for _, span in ipairs(selected) do
    w = w + maki.ui.display_width(span[1])
  end
  check.eq(w, width, "the row fills the window width")

  local plain = t.color_row({ label = "default (theme)" }, true, width, "#202020")
  check.eq(plain[1][2], "selected", "a row with no color keeps the selection style")
end

cases.running_count_counts_only_working_tasks = function(check)
  check.eq(t.running_count(nil), 0)
  check.eq(t.running_count({}), 0)
  check.eq(t.running_count({ a = "working" }), 1)
  check.eq(t.running_count({ a = "working", b = "working", c = "idle" }), 2)
  check.eq(t.running_count({ a = "done", b = "error", c = "cancelled" }), 0)
end

return { cases = cases, name = "session_bar" }
