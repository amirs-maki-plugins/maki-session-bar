-- session_bar: shows [session-name] on the lower line of the prompt box.
--
-- Commands:
--   /color [color]    set the color of the name block and the
--                              input box border together; no argument opens
--                              a picker (swatch names only). "default" or
--                              "reset" restores the theme's own colors.
--
-- The bar draws its name block only: the host draws the border line the
-- block sits on, so the line keeps the theme's own color and mode tint.
--
-- The name is truncated to 30 display cells. The color is per-session:
-- /color applies it live through maki.ui.set_theme_style and records it
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
-- A host without set_theme_style cannot repaint the border, so the bar
-- offers no /color command there instead of one that does nothing.
local CAN_PAINT = maki.ui.set_theme_style ~= nil
-- A host-side close re-opens the window, but not forever: at most
-- REOPEN_BUDGET re-opens per REOPEN_WINDOW_S, so a host that keeps
-- closing the window cannot spin the plugin.
local REOPEN_BUDGET = 3
local REOPEN_WINDOW_S = 30
local REOPEN_DELAY_MS = 100

local opts = {
  name_color = nil, -- nil = the theme's own border color
}

-- Whether this session's agent is working, seeded from the session read and
-- kept current by SessionStatusChanged. Only "working" fades the rule.
local working = {}
-- How far the rule fades toward the background while the agent works.
local DIM_FACTOR = 0.55
-- The color is remembered per session id in session_colors.json: /color
-- writes it, and the focus handler re-applies it when the session comes
-- back (a restart, a tab switch). A session without a saved entry runs
-- on the theme's own colors.

-- ---------------------------------------------------------------- color ----

local function name_bg()
  if opts.name_color then
    -- a palette name ("blue"), hex, or "default"; spans and
    -- set_theme_style both resolve names against the running theme
    return opts.name_color
  end
  -- no saved color: the color the theme gives the input box at rest, so
  -- the name block always matches the rule the input box paints
  local style = maki.ui.theme_style and maki.ui.theme_style("mode_build")
  local c = style and style.fg
  if c and c ~= "default" then
    return c
  end
  return "#808080"
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
local apply_border_style -- forward declaration; defined in the colors section
local rule_style -- forward declaration; defined in the colors section
local apply_session_color -- forward declaration; defined in the colors section
local watch_close -- forward declaration; defined in the events section

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

-- (Re)writes the bar's single line into the persistent buffer: one blank
-- cell, then the name block with the running-task badge when there is one.
-- The window is no wider than that, so the host draws the rest of the
-- border line underneath it.
local function paint_line(label, nbg, nfg)
  if not bar_buf then
    return
  end
  bar_buf:set_lines({
    { { " ", {} }, { label, { fg = nfg, bg = nbg, bold = true } } },
  })
end

-- One blank cell before the block, so the theme's line does not run into it.
local function label_width(label)
  return maki.ui.display_width(label) + 1
end

-- The window follows the label: a badge appearing, a count reaching two
-- digits, a longer name. A spinner frame is one cell, so it never patches.
local bar_width
local function fit_width(win, label)
  local width = label_width(label)
  if width == bar_width then
    return
  end
  bar_width = width
  if win then
    pcall(function()
      win:set_config({ width = width })
    end)
  end
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
  apply_border_style(rule_style())
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
    paint_line(label, nbg, readable_fg(nbg))
    fit_width(bar_win, label)
    return
  end

  local buf = maki.ui.buf({ scratch = true })
  bar_buf = buf
  paint_line(label, nbg, readable_fg(nbg))

  local wopts = {
    anchor = "SE",
    row = -1, -- the prompt box's bottom border line
    col = 0, -- flush against the right edge of that line
    width = label_width(label),
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
    bar_width = label_width(label)
    watch_close(win)
  else
    maki.log.error(PLUGIN .. ": open_win failed: " .. tostring(win))
    bar_win = nil
    bar_buf = nil
    bar_width = nil
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
    working[sid] = snap.status == "working"
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
    local sid = (ev.data or {}).session_id or ""
    tasks[sid] = nil
    working[sid] = nil
  end,
})

-- A turn starts or ends. Only the rule changes: it fades toward the
-- background while the agent in front works, the way the host dims its own
-- chrome, and comes back to the session's color when the turn ends.
maki.api.create_autocmd("SessionStatusChanged", {
  callback = function(ev)
    local d = ev.data or {}
    if not d.session_id then
      return
    end
    working[d.session_id] = d.status == "working"
    if d.session_id == cur_id then
      apply_border_style(rule_style())
    end
  end,
})

-- A close from the host is not the end of the bar. The host closes
-- session windows on its own (a reset, a reload, a tab juggle, a
-- sleep/wake cycle), and no title, cwd or focus autocmd follows some of
-- those, so a bar that only re-rendered on events would stay gone. A
-- close therefore re-opens the window when the session is still focused
-- and its title still warrants a bar; a session that lost its tab stays
-- closed, because its focus event re-opens the bar when it returns.
local reopens, last_reopen = 0, 0
watch_close = function(win)
  if not win then
    return
  end
  maki.async.spawn(function()
    while bar_win == win do
      local ev = win:recv()
      if not ev or ev.type == "close" then
        bar_win = nil
        bar_buf = nil
        local e = cur_id and cache[cur_id]
        local wanted = e and e.title and e.title ~= "" and e.title ~= "New session"
        local now = os.time()
        if now - last_reopen > REOPEN_WINDOW_S then
          reopens = 0
        end
        if wanted and reopens < REOPEN_BUDGET and maki.session.current() == cur_id then
          reopens = reopens + 1
          last_reopen = now
          maki.defer_fn(function()
            guard(render_bar, "reopen")
          end, REOPEN_DELAY_MS)
        end
        return
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
  apply_border_style(rule_style())
end

-- ------------------------------------------------------------- theme io ----
-- The rule's color lives in the maki theme, outside the plugin. /color keeps
-- the two in step: the same hex paints the rule and the [name] block, and
-- the rule fades toward the background while the agent works.

local function rgb(hex)
  if type(hex) ~= "string" then
    return nil
  end
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then
    return nil
  end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function lerp(from, to, t)
  return math.floor(from + (to - from) * t + 0.5)
end

-- A hex color blends cell by cell toward the background, which is the same
-- fade the host applies to its own chrome. A palette or ANSI color has no
-- RGB here, so it falls back to the terminal's dim attribute.
local function fade(hex)
  local r, g, b = rgb(hex)
  local br, bg, bb = rgb(maki.ui.theme_color and maki.ui.theme_color("background"))
  if not r or not br then
    return { fg = hex, dim = true }
  end
  return {
    fg = string.format(
      "#%02x%02x%02x",
      lerp(r, br, DIM_FACTOR),
      lerp(g, bg, DIM_FACTOR),
      lerp(b, bb, DIM_FACTOR)
    ),
  }
end

-- What the rule should be: the session's color, faded while the agent
-- works, and nothing at all when the session has no color, so the theme's
-- own rule and its busy style apply.
rule_style = function()
  local color = opts.name_color
  if not color or color == "default" then
    return nil
  end
  if working[cur_id] then
    return fade(color)
  end
  return { fg = color }
end

-- A paint of the same style is not repeated: the host rebuilds the whole
-- theme for one call, and the bar renders on every tick.
local last_painted
apply_border_style = function(style)
  if not CAN_PAINT then
    return
  end
  local key = {}
  if style then
    key[#key + 1] = tostring(style.fg)
    key[#key + 1] = style.dim and "dim" or ""
  end
  key = table.concat(key, "|")
  if key == last_painted then
    return
  end
  last_painted = key
  -- one key paints the whole rule: the transcript separator and the input
  -- box border
  maki.ui.set_theme_style("separator", style)
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
  opts.name_color = c
  apply_border_style(rule_style())
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
      apply_border_style(rule_style())
      persist_color(cur_id, nil)
      guard(render_bar, "render")
      return
    end
    set_color(choice.item.value)
  end
end

if CAN_PAINT then
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
        apply_border_style(rule_style())
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
end

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
    fade = fade,
    label_width = label_width,
  },
}
