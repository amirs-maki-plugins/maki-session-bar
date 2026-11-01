-- session_bar: shows [session-name] on the lower line of the prompt box.
--
-- Commands:
--   /color [color]    set the color of the name block and the
--                              input box border together; no argument opens
--                              a picker (swatch names only). "default" or
--                              "reset" restores the theme's own colors.
--
-- The name is truncated to 30 display cells. The color is per-session:
-- /color applies it live through maki.ui.set_theme_color and records it
-- in ~/.local/state/maki/session_colors.json, so a session restored
-- after a restart comes back with the color it left with.
--
-- Data flow: the title and the cwd arrive as autocmd payloads and land in a
-- per-session cache; a render is pure cache work and never reads the
-- session. maki.session.read() runs once per session, on first sight of it
-- (startup, focus switch), because a title set before this run never
-- arrives as an event. The bar shows every real title, auto-generated ones
-- included.

local ListPicker = require("maki.list_picker")
local swatches = require("swatches")

local PLUGIN = "session_bar"
local MAX_CELLS = 30
local BORDER_STYLES = { "mode_build", "mode_plan", "mode_bash" }

local opts = {
  name_color = nil, -- nil = the theme's own border color
}
-- The color is remembered per session id in session_colors.json: /color
-- writes it, and the focus handler re-applies it when the session comes
-- back (a restart, a tab switch). A session without a saved entry runs
-- on the theme's own colors.

-- ---------------------------------------------------------------- color ----

local function name_bg()
  if opts.name_color then
    -- a palette name ("blue"), hex, or "default"; spans and
    -- set_theme_color both resolve names against the running theme
    return opts.name_color
  end
  -- no saved color: the theme's own border color, so the name block
  -- always matches the dashes the input box paints
  local c = maki.ui.get_theme_color and maki.ui.get_theme_color("mode_build")
  if c and c ~= "default" then
    return c
  end
  return "#808080"
end

-- The input box paints its border with `input_border` while the agent
-- works, so the name block and the box would split into two colors. Pin
-- that style to the name color: the box keeps one color for the whole turn.
local last_busy_color
local function pin_busy_color(color)
  if not maki.ui.set_theme_color or color == last_busy_color then
    return
  end
  last_busy_color = color
  local ok, err = maki.ui.set_theme_color("input_border", color)
  if not ok then
    maki.log.error(PLUGIN .. ": pin busy color: " .. tostring(err))
  end
end

local function readable_fg(bg)
  if bg == "default" then
    return "default"
  end
  local r, g, b = bg:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then
    return "default" -- a palette name or ANSI index: the theme picks its own ink
  end
  local lum = 0.2126 * tonumber(r, 16) + 0.7152 * tonumber(g, 16) + 0.0722 * tonumber(b, 16)
  return lum > 127 and "#101010" or "#f0f0f0"
end

-- --------------------------------------------------------------- title -----

local function short_title(title, max)
  if maki.ui.display_width(title) <= max then
    return title
  end
  local cut, w = 0, 0
  local i = 1
  while i <= #title do
    local b = title:byte(i)
    local cl = 1
    if b >= 0xF0 then
      cl = 4
    elseif b >= 0xE0 then
      cl = 3
    elseif b >= 0xC0 then
      cl = 2
    end
    local ch = title:sub(i, i + cl - 1)
    local cw = maki.ui.display_width(ch)
    if w + cw > max - 1 then
      break
    end
    w = w + cw
    cut = i + cl - 1
    i = i + cl
  end
  return title:sub(1, cut) .. "…"
end

-- ------------------------------------------------------------------ bar ----

local bar_win
local bar_buf
local last_win_title
local apply_border_colors -- forward declaration; defined in the colors section
local apply_session_color -- forward declaration; defined in the colors section
local watch_resizes -- forward declaration; defined in the events section

-- What the bar knows about each session: { title, cwd } keyed by session
-- id, filled by autocmd payloads. Rendering reads only this cache.
local cache = {}
-- The session on screen. The focus event sets it, and so does a title
-- event for the focused tab (a reset or a load swaps the id in place).
local cur_id

-- session id -> { [task id] = status }. A subagent counts as running while
-- its status is "working"; a plugin task between prompts is "idle".
local tasks = {}

local function running_count(task_statuses)
  local n = 0
  for _, status in pairs(task_statuses or {}) do
    if status == "working" then
      n = n + 1
    end
  end
  return n
end

local function running_tasks(sid)
  return running_count(tasks[sid])
end

-- The same braille spinner the status bar runs, one frame per repaint
-- while a task works, stopped as soon as none does.
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_MS = 120
local spin = { frame = 1, timer = nil }
local spin_start -- forward declaration; render_bar re-arms it

local function spin_stop()
  if spin.timer then
    spin.timer:stop()
    spin.timer = nil
  end
end

local function bar_label(title)
  local label = "[" .. short_title(title, MAX_CELLS) .. "]"
  local running = running_tasks(cur_id)
  if running > 0 then
    label = label .. " " .. SPINNER_FRAMES[spin.frame] .. " " .. running
  end
  return label
end

local function entry(sid)
  if not sid then
    return nil
  end
  local e = cache[sid]
  if not e then
    e = {}
    cache[sid] = e
  end
  return e
end

local function guard(fn, what)
  local ok, err = pcall(fn)
  if not ok then
    maki.log.error(PLUGIN .. ": " .. what .. " failed: " .. tostring(err))
  end
end

local function close_bar()
  if bar_win then
    pcall(function() bar_win:close() end)
    bar_win = nil
  end
  bar_buf = nil
end

-- terminal title: "<title> - <short cwd> (maki)" when titled, "maki - <short
-- cwd>" when not. The cwd collapses like macOS window titles do: every
-- component except the last keeps its first letter
-- (~/Documents/inference/vllm -> ~/D/i/vllm); under ~ the first component
-- stays whole.
local function mac_short(path)
  local prefix = ""
  local rest = path
  if rest:sub(1, 1) == "/" then
    prefix = "/"
    rest = rest:sub(2)
  end
  local parts = {}
  for part in rest:gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  if #parts <= 1 then
    return path
  end
  local out = {}
  for i, part in ipairs(parts) do
    if i == #parts then
      out[i] = part
    else
      out[i] = part:sub(1, 1)
    end
  end
  return prefix .. table.concat(out, "/")
end

local function short_cwd(cwd)
  if not cwd or cwd == "" then
    return nil
  end
  if maki.uv and maki.uv.os_homedir then
    local home = maki.uv.os_homedir()
    if home and home ~= "" and cwd:sub(1, #home) == home then
      local rest = cwd:sub(#home + 1)
      if rest == "" then
        return "~"
      end
      return "~/" .. mac_short(rest:sub(2))
    end
  end
  return mac_short(cwd)
end

local function win_title(title, cwd)
  if cwd then
    if title then
      return title .. " - " .. cwd .. " (maki)"
    end
    return "maki - " .. cwd
  end
  if title then
    return title .. " (maki)"
  end
  return "maki"
end

-- (Re)writes the bar's single line into the persistent buffer. cols comes
-- from the terminal size, or from a resize event after the host moved the
-- window.
local function paint_line(label, nbg, nfg, cols)
  local label_w = maki.ui.display_width(label)
  -- The window covers the input box's own bottom border line, so the dashes
  -- are redrawn here, in the same color as the name block. One blank cell
  -- separates the dashes from the label; the label itself ends flush at
  -- the window's right edge.
  local dashes = math.max(cols - label_w - 1, 1)
  if not bar_buf then
    return
  end
  bar_buf:set_lines({
    { { string.rep("-", dashes), { fg = nbg } }, { " ", {} },
      { label, { fg = nfg, bg = nbg, bold = true } } },
  })
end

local function render_bar()
  if running_tasks(cur_id) > 0 then
    spin_start()
  else
    spin_stop()
  end
  local e = cur_id and cache[cur_id]
  local title = e and e.title
  local cwd = e and e.cwd
  pin_busy_color(name_bg())
  local show_bar = e and title and title ~= "" and title ~= "New session"

  -- terminal window title follows the session name and cwd; untruncated,
  -- and shown for any real title, user-set or auto-generated.
  if maki.ui.set_window_title then
    local display = (title and title ~= "" and title ~= "New session") and title or nil
    local wt = win_title(display, short_cwd(cwd))
    if wt ~= last_win_title then
      pcall(maki.ui.set_window_title, wt)
      last_win_title = wt
    end
  end

  if not show_bar then
    close_bar()
    return
  end

  local label = bar_label(title)
  local nbg = name_bg()

  -- One persistent window: resizes and title changes rewrite its buffer
  -- with set_lines instead of tearing the window down, so the bar never
  -- flickers against the input box it sits on.
  if bar_win and bar_win.is_open and bar_win:is_open() and bar_buf then
    local size = maki.ui.terminal_size()
    paint_line(label, nbg, readable_fg(nbg), size.cols)
    return
  end

  local size = maki.ui.terminal_size()
  local buf = maki.ui.buf({ scratch = true })
  bar_buf = buf
  paint_line(label, nbg, readable_fg(nbg), size.cols)

  local wopts = {
    anchor = "SW",
    row = -1, -- the prompt box's bottom border line
    col = 0,
    width = "100%",
    height = 1,
    border = "none",
    focus = false,
    zindex = 40,
  }
  if cur_id then
    -- A window belongs to one session and closes when its tab loses focus,
    -- so the bar must name the session it currently paints for.
    wopts.session = cur_id
  end
  local ok, win = pcall(maki.ui.open_win, buf, wopts)
  if ok then
    bar_win = win
    watch_resizes(win)
  else
    maki.log.error(PLUGIN .. ": open_win failed: " .. tostring(win))
    bar_win = nil
    bar_buf = nil
  end
end

-- One frame per tick while a task runs; render_bar re-arms the timer, so
-- the animation dies with the last running task and never outlives the
-- bar it was started for.
spin_start = function()
  if spin.timer == nil then
    spin.timer = maki.defer_fn(function()
      spin.timer = nil
      spin.frame = spin.frame % #SPINNER_FRAMES + 1
      guard(render_bar, "spin")
    end, SPINNER_MS)
  end
end

-- --------------------------------------------------------------- events ----

-- First sight of a session: read it once. A title set before this run (a
-- loaded or resumed tab) never arrives as an event, so the cache has to be
-- seeded; from then on the payloads keep it current. Runs inside an autocmd
-- callback, which may suspend while the UI answers the read.
local function seed(sid)
  local e = entry(sid)
  if e.seeded then
    return
  end
  local snap, err = maki.session.read({ session = sid })
  if snap then
    e.seeded = true
    if snap.title and snap.title ~= "" then
      e.title = snap.title
    end
    if snap.cwd and snap.cwd ~= "" then
      e.cwd = snap.cwd
    end
    -- A reload inside a turn replays no task event, so seed the live tasks.
    local list = maki.task.list()
    local t = {}
    for _, row in ipairs(list or {}) do
      if row.id and row.status then
        t[row.id] = row.status
      end
    end
    tasks[sid] = t
  elseif err and err ~= "no interactive UI attached" then
    maki.log.error(PLUGIN .. ": session read: " .. tostring(err))
  end
end

maki.api.create_autocmd({
  "SessionTitleChanged",
  "SessionFocusChanged",
  "SessionCwdChanged",
}, {
  callback = function(ev)
    local d = ev.data or {}
    if d.session_id == nil then
      return
    end
    if d.focused == false then
      return
    end
    if ev.event == "SessionFocusChanged" or d.session_id ~= cur_id then
      cur_id = d.session_id
    end
    local e = entry(d.session_id)
    if ev.event == "SessionTitleChanged" then
      e.title = d.title
      render_bar()
    elseif ev.event == "SessionCwdChanged" then
      e.cwd = d.cwd
      render_bar()
    else
      -- A tab taking focus may hold a title this run never heard about.
      seed(d.session_id)
      -- the borders follow the focused session's saved color
      apply_session_color(d.session_id)
      render_bar()
    end
  end,
})

-- Tasks a subagent starts or finishes, and the stop that can come in the
-- same frame. The badge counts them, so a changed task repaints the bar.
maki.api.create_autocmd("TaskStatusChanged", {
  callback = function(ev)
    local d = ev.data or {}
    if not d.session_id or not d.id then
      return
    end
    local t = tasks[d.session_id] or {}
    tasks[d.session_id] = t
    if d.status == "done" or d.status == "error" or d.status == "cancelled" then
      t[d.id] = nil
    else
      t[d.id] = d.status
    end
    if d.session_id == cur_id then
      guard(render_bar, "task render")
    end
  end,
})

maki.api.create_autocmd("TaskStopped", {
  callback = function(ev)
    local d = ev.data or {}
    if d.session_id and d.id and tasks[d.session_id] then
      tasks[d.session_id][d.id] = nil
      if d.session_id == cur_id then
        guard(render_bar, "task render")
      end
    end
  end,
})

maki.api.create_autocmd({ "SessionReset", "SessionEnd" }, {
  callback = function(ev)
    tasks[(ev.data or {}).session_id or ""] = nil
  end,
})

-- A terminal resize changes the dash count, so the bar must re-render.
-- A terminal resize changes the dash count. The float manager sends the
-- bar window a resize event whenever its content area changes; this
-- listener repaints the persistent buffer at the new width. The window
-- itself is never torn down, so nothing flickers.
watch_resizes = function(win)
  if not win then
    return
  end
  maki.async.spawn(function()
    while bar_win == win do
      local ev = win:recv()
      if not ev or ev.type == "close" then
        return
      end
      if ev.type == "resize" then
        local e = cur_id and cache[cur_id]
        local title = e and e.title
        if title and title ~= "" and title ~= "New session" then
          -- ev.width is the window's content width, borderless here, so it
          -- is the terminal width the dashes must fill
          local label = bar_label(title)
          local nbg = name_bg()
          guard(function()
            paint_line(label, nbg, readable_fg(nbg), ev.width)
          end, "resize repaint")
        end
      end
    end
  end)
end

-- -------------------------------------------------------------- colors ----

-- The picker list and name-to-hex resolution live in the shared swatches
-- module, so every plugin that offers a color pick offers the same colors
-- (progress_bar's `color` option uses it too).
local swatch_list = swatches.swatch_list

-- ------------------------------------------------------ saved colors ----
-- session id -> hex, in ~/.local/state/maki/session_colors.json. /color
-- writes it; the focus handler reads it, so a restored session keeps
-- its color and a session without one resets the borders to the theme.

local COLORS_FILE = "~/.local/state/maki/session_colors.json"
local saved_colors

local function valid_saved_color(value)
  return value == "default" or type(value) == "string"
    and value:match("^#%x%x%x%x%x%x$") ~= nil
end

local function sanitize_colors(t)
  local out = {}
  if type(t) == "table" then
    for sid, c in pairs(t) do
      if type(sid) == "string" and sid ~= "" and valid_saved_color(c) then
        out[sid] = c
      end
    end
  end
  return out
end

local function load_colors()
  if not saved_colors then
    saved_colors = {}
    local text = maki.fs.read(COLORS_FILE)
    if text and text ~= "" then
      local t, err = maki.json.decode(text)
      if t then
        saved_colors = sanitize_colors(t)
      else
        maki.log.error(PLUGIN .. ": colors file: " .. tostring(err))
      end
    end
  end
  return saved_colors
end

local function persist_color(sid, value)
  if not sid then
    return -- no session to key it under; applied live only
  end
  load_colors()
  if value == nil then
    saved_colors[sid] = nil
  else
    saved_colors[sid] = value
  end
  local s, err = maki.json.encode(saved_colors)
  if not s then
    maki.log.error(PLUGIN .. ": encode colors: " .. tostring(err))
    return
  end
  local ok, werr = maki.fs.write(COLORS_FILE, s)
  if not ok then
    maki.log.error(PLUGIN .. ": write colors: " .. tostring(werr))
  end
end

-- The focused session's color: nil means the theme's own. Skipped when
-- the wanted color is already on screen, so a focus event never churns
-- the theme.
apply_session_color = function(sid)
  local c = sid and load_colors()[sid] or nil
  if c == opts.name_color then
    return
  end
  opts.name_color = c
  local ok, err = apply_border_colors(c)
  if not ok then
    maki.log.error(PLUGIN .. ": apply saved color: " .. tostring(err))
  end
end

-- ------------------------------------------------------------- theme io ----
-- The input box border color lives in the maki theme, outside the plugin.
-- /color keeps the user theme in sync with the name color: same
-- hex, so the dashes and the [name] block always match.

apply_border_colors = function(color)
  if not maki.ui.set_theme_color then
    return true
  end
  for _, style in ipairs(BORDER_STYLES) do
    local c = color
    if c == "default" or c == nil then
      c = nil -- restore the theme's own color
    end
    local ok, err = maki.ui.set_theme_color(style, c)
    if not ok then
      -- a rejected color must not half-apply: the first style that
      -- refuses stops the loop and the error reaches the user
      return false, err
    end
  end
  return true
end

local function canonical_color(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if value == "default" then
    return "default"
  end
  -- the picker hands over the hex already; typed input is a swatch name
  if value:match("^#%x%x%x%x%x%x$") then
    return value
  end
  return swatches.resolve(value)
end

local function set_color(value)
  local c = canonical_color(value)
  if not c then
    maki.ui.flash("'" .. tostring(value) .. "' is not a color. Use a swatch name (see the picker) or 'default'.")
    return
  end
  local applied, err = apply_border_colors(c)
  if not applied then
    -- nothing changed: no saved color, no repaint, the error says why
    maki.ui.flash(tostring(err))
    return
  end
  opts.name_color = c
  persist_color(cur_id, c)
  guard(render_bar, "render")
end

local function pick_color()
  local items = {
    {
      label = "default (theme)",
      value = nil,
      detail = { { "  default (theme's own border color)  ", { fg = "default" } } },
    },
  }
  for _, sw in ipairs(swatch_list()) do
    local hex = sw.hex
    items[#items + 1] = {
      label = sw.label,
      -- the hex is what gets applied; the names are only a label
      -- here, so the color never depends on later resolution
      value = hex,
      detail = { { "  " .. sw.label .. "  ", { bg = hex, fg = readable_fg(hex) } } },
    }
  end
  local choice = ListPicker.open(items, {
    title = "Session name + border color",
    footer = { { "<CR>", "select" }, { "<Esc>", "cancel" } },
    cursor = 1,
  })
  if choice and choice.type == "choice" and choice.item then
    if choice.item.value == nil then
      -- "default (theme)": same as reset
      opts.name_color = nil
      apply_border_colors(nil)
      persist_color(cur_id, nil)
      guard(render_bar, "render")
      return
    end
    set_color(choice.item.value)
  end
end

maki.api.register_command({
  name = "/color",
  description = "Set the session-name and border color: /color [name|default|reset]",
  nargs = "*",
  handler = function(copts)
    local fargs = copts.fargs or {}

    if #fargs == 0 then
      pick_color()
      return
    end

    local cmd = fargs[1]

    if cmd == "reset" then
      opts.name_color = nil
      apply_border_colors(nil)
      persist_color(cur_id, nil)
      guard(render_bar, "render")
      return
    end

    if fargs[2] == nil then
      set_color(cmd)
      return
    end

    maki.ui.flash("Usage: /color [name|default] | reset")
  end,
})

-- first paint once the UI has settled. A restored session emits no title
-- event (the host seeds last_title from the loaded title), so if no focus
-- event arrived either, ask the host which session is focused and seed it
-- here instead of painting an empty cache.
maki.defer_fn(function()
  if not cur_id then
    local sid = maki.session.current()
    if sid and sid ~= "" then
      cur_id = sid
      seed(sid)
      apply_session_color(sid)
    end
  end
  guard(render_bar, "first render")
end, 300)

-- Test seam: the pure helpers, for session_bar_spec (run via /spec).
return {
  _test = {
    readable_fg = readable_fg,
    short_title = short_title,
    mac_short = mac_short,
    win_title = win_title,
    short_cwd = short_cwd,
    valid_color = canonical_color,
    valid_saved_color = valid_saved_color,
    sanitize_colors = sanitize_colors,
    running_count = running_count,
  },
}
