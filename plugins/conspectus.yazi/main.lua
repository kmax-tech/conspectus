-- conspectus.yazi — bundled glue between yazi and the conspectus app.
-- Shipped inside the conspectus repo and injected into the overlay config by
-- bin/conspectus; the user's own yazi config is never touched, and no
-- external binaries are needed.
--
-- Six jobs:
--   1. Preview coupling: every hover writes the hovered path to the FIFO the
--      app hands us via $QLPEEK_FIFO, preceded by the tab's sort preference
--      as `@SORT:<by>:<reverse>:<dir_first>` (the app's folder listing
--      orders itself like yazi's columns; yazi re-hovers after every `sort`,
--      so the pair always arrives together); every yank change writes the
--      buffer as `@YANK:<copy|cut>:<paths>` (the app's shortcut bar mirrors it).
--      Written directly from Lua — the app
--      holds the FIFO open read-write for its whole lifetime, so opening it
--      for append returns immediately (a FIFO open-for-write only blocks
--      when no reader exists, and yazi dies with the app anyway).
--   2. panesync: follow the app's DDS messages — `panesync-cd` / `-reveal`
--      (a row clicked in the preview listing, or the user's `=` key),
--      `panesync-history` (the mouse's back/forward buttons, ⌘[ / ⌘]),
--      `panesync-restart` (re-theme after light↔dark and ⌘R; refused over
--      the FIFO as `@RESTART_REFUSED:…` while the pane is busy),
--      `panesync-selected` (⌘L asks for the selection, answered over the
--      FIFO), `panesync-act` (the right-click menu's file operations, run on
--      the hovered item), plus `conspectus-open` from the shell. Guarded by $CONSPECTUS_PEER, which only conspectus sets, so a
--      plain terminal yazi never follows.
--   3. Tab session: snapshot this pane's tabs on every cd and restore them
--      when the app asks, so tabs survive ⌘R and app restarts.
--   4. Navigation that asks the HOVERED entry, not the selection: the `entry`
--      below (`l`/`→` and `o`/`<Enter>`), and Finder's mouse contract on the
--      rows — a click marks (stock yazi), a double-click enters a folder or
--      opens a file like Enter. yazi has no double-click; two clicks on the
--      same row within the macOS interval ($CONSPECTUS_DOUBLE_CLICK) are one.
--   5. A clickable path bar: the cwd in the pane's header is a breadcrumb, so
--      the mouse can go UP as well as down (the columns only ever go down).
--   6. Automount: a cd into a mount point from the launcher's automount file
--      has the launcher check it and mount it again when it is missing or
--      dead (`conspectus automount`); the verdict shows as a notification.

local M = {}

-- Seconds between two automount checks of the same mount point (job 6).
local AUTOMOUNT_RECHECK = 30

-- Append one line to the app's FIFO. Never blocks: the app holds its FIFO open
-- read-write for its whole life, so the open-for-append returns at once. A
-- FIFO that cannot be opened (app gone) is a silent no-op — yazi dies with the
-- app anyway, and there is nobody left to tell.
local function fifo_write(fifo, line)
	local f = io.open(fifo, "a")
	if not f then return end
	f:write(line .. "\n")
	f:close()
end

-- A file operation the app's context menu asked for (`panesync-act`) that
-- waits for its path to become the hovered item — see the handler below.
-- { cmd = <one of act_commands>, path = "<abs path>" } or nil.
local pending_act = nil

local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	return h and tostring(h.url) or nil
end)

-- The active tab's sort preference as the `@SORT:` body: `<by>:<reverse>:
-- <dir_first>` with the booleans as Lua's "true"/"false". Read from yazi's
-- tab preference (cx.active.pref, yazi 26). Errors (API drift) propagate to
-- the caller, which reports once and leaves the app on its previous order.
local get_sort = ya.sync(function()
	local p = cx.active.pref
	return p.sort_by .. ":" .. tostring(p.sort_reverse) .. ":" .. tostring(p.sort_dir_first)
end)
local sort_warned = false

-- Rows of air between the header (the path) and the tab bar; yazi's own
-- layout has none, and the two lines read as one block. Only with the tab
-- bar — a single tab has no bar, and the list follows the path as in yazi.
local HEADER_GAP_ROWS = 1

-- The terminal row (0-based) where the active tab's file list starts, as the
-- `@LIST_TOP:` body: the header (1 row), then with more than one tab the
-- gap and the tab bar (`Tabs.height()` is 1 then, else 0) — the layout
-- `install_header_gap` builds. The app puts the folder listing's rows on
-- the same rows of its pane.
local get_list_top = ya.sync(function()
	local bar = #cx.tabs > 1 and 1 or 0
	return tostring(1 + bar * (HEADER_GAP_ROWS + 1))
end)

-- Root:layout with HEADER_GAP_ROWS of air after the header, in conspectus
-- panes only (terminal yazi keeps its own layout). yazi's Root:build reads
-- self._chunks[1..4] (header, tabs, tab, status), so the gap is split off
-- here and dropped — the chunk list the builder sees stays four long.
local function install_header_gap()
	if type(Root) ~= "table" or type(Root.layout) ~= "function" then
		ya.notify({ title = "conspectus", timeout = 5, level = "warn",
			content = "header gap not installed — yazi's Root:layout is missing" })
		return
	end
	Root.layout = function(self)
		local gap = Tabs.height() > 0 and HEADER_GAP_ROWS or 0
		local c = ui.Layout()
			:direction(ui.Layout.VERTICAL)
			:constraints({
				ui.Constraint.Length(1),
				ui.Constraint.Length(gap),
				ui.Constraint.Length(Tabs.height()),
				ui.Constraint.Fill(1),
				ui.Constraint.Length(1),
			})
			:split(self._area)
		self._chunks = { c[1], c[3], c[4], c[5] }
	end
end

-- Whether the item UNDER THE CURSOR is a directory — read from yazi's real
-- state, so it's correct even with files selected (unlike a shell `[ -d "$1" ]`
-- test, where "$1" is the first SELECTED file, not the hovered one).
local hovered_is_dir = ya.sync(function()
	local h = cx.active.current.hovered
	return h ~= nil and h.cha.is_dir
end)

-- Open the hovered file the way `o` / Enter do: in IDE mode ($CONSPECTUS_NVIM
-- = the middle nvim's --listen socket) send the selected/hovered text file(s)
-- there as buffers, so several files pile up in one editor; otherwise yazi's
-- normal opener. Selection semantics are Enter's: a pending selection opens
-- as a batch. Shared by the keymap entry, the double-click and the app's
-- `panesync-act open`.
local function open_hovered()
	local emit = ya.emit or ya.mgr_emit
	local oks, sock = pcall(function() return os.getenv("CONSPECTUS_NVIM") end)
	if oks and sock and #sock > 0 then
		-- The socket may be stale (IDE pane closed since launch), so the
		-- liveness test stays in the shell, next to the nvim call. A binary
		-- file (PDF, image) is never sent there — nvim would show raw bytes —
		-- but goes to the normal opener. The test looks at "$1" only (first
		-- selected, else hovered): a mixed selection follows its first file.
		emit("shell", { 'if [ -S "$CONSPECTUS_NVIM" ] && [ "$(file -b --mime-encoding -- "$1")" != binary ]; then nvim --server "$CONSPECTUS_NVIM" --remote "$@"; else ya emit open; fi' })
	else
		emit("open", {})
	end
end

-- `E C` inside conspectus: lazycvs for the HOVERED item, via the app's
-- FIFO (`@LAZYCVS:<path>`) — the app opens lazycvs in its terminal panel,
-- the same action as the context menu's "Open in lazycvs"; outside a
-- checkout the app beeps and says why. Written from Lua, NOT from a
-- `shell … --block` in the keymap (the original form): a blocking shell
-- hands the terminal to its child and yazi re-probes the terminal (DA1
-- query) when it resumes; the app's reaction to the message — opening the
-- panel resizes the yazi pane — lands exactly in that probe, its read fails
-- with EINTR, yazi exits, and the app closes with its left pane. A plain
-- terminal yazi (no FIFO) never gets here: the keymap runs lcvs itself.
local function lazycvs_hovered()
	local ok, fifo = pcall(function() return os.getenv("QLPEEK_FIFO") end)
	if not (ok and fifo and #fifo > 0) then
		ya.notify({ title = "conspectus", timeout = 3, level = "warn",
			content = "lazycvs: no conspectus FIFO — this mode only works inside the app" })
		return
	end
	local path = get_hovered()
	if not path then
		ya.notify({ title = "conspectus", timeout = 3, level = "warn",
			content = "lazycvs: nothing hovered" })
		return
	end
	fifo_write(fifo, "@LAZYCVS:" .. path)
end

-- Copy / cut for the context menu. yazi's `yank` takes the selection when
-- there is one (it has no `--hovered`), so: no selection → the hovered item;
-- hovered item inside the selection → the whole selection (Finder's rule for
-- a right-click on a selected item); hovered item outside it → refuse and
-- say why, never yank files the user did not click. Sync context (cx).
local function yank_hovered(cut)
	local h = cx.active.current.hovered
	if not h then
		ya.notify({ title = "conspectus", timeout = 3, level = "warn", content = "copy/cut: nothing hovered" })
		return
	end
	local hovered, any, inside = tostring(h.url), false, false
	for _, url in pairs(cx.active.selected) do
		any = true
		if tostring(url) == hovered then inside = true end
	end
	if any and not inside then
		ya.notify({ title = "conspectus", timeout = 5, level = "warn",
			content = "copy/cut: other files are selected — clear the selection (Esc) or right-click a selected file" })
		return
	end
	(ya.emit or ya.mgr_emit)("yank", cut and { cut = true } or {})
end

-- Run a `panesync-act` command where the context menu asked for it:
-- rename/remove are yazi's own, restricted to the hovered item; copy/cut fill
-- the yank buffer (see yank_hovered); newfile/newdir/paste act in the current
-- folder (the clicked item's parent after the reveal); open is the shared
-- opener above.
local function run_act(cmd)
	local emit = ya.emit or ya.mgr_emit
	if cmd == "open" then
		open_hovered()
	elseif cmd == "copy" or cmd == "cut" then
		yank_hovered(cmd == "cut")
	elseif cmd == "newfile" then
		emit("create", {})
	elseif cmd == "newdir" then
		emit("create", { dir = true })
	elseif cmd == "paste" then
		emit("paste", {})
	else
		emit(cmd, { hovered = true })
	end
end

-- The commands `panesync-act` accepts (see run_act).
local act_commands = {
	rename = true, remove = true, open = true,
	copy = true, cut = true, paste = true, newfile = true, newdir = true,
}

-- Double-click interval in seconds: the macOS setting (System Settings →
-- Mouse), handed over by the app as $CONSPECTUS_DOUBLE_CLICK
-- (NSEvent.doubleClickInterval). Unset — a yazi the app did not launch, which
-- never installs the click handler anyway — or unparsable falls back to
-- macOS's own default of 0.5 s; the unparsable case is reported.
local function double_click_interval()
	local ok, v = pcall(function() return os.getenv("CONSPECTUS_DOUBLE_CLICK") end)
	if not ok or v == nil or v == "" then return 0.5 end
	local n = tonumber(v)
	if not n or n <= 0 then
		ya.notify({ title = "conspectus", timeout = 5, level = "warn",
			content = "CONSPECTUS_DOUBLE_CLICK='" .. v .. "' is not a positive number — double-click uses 0.5 s" })
		return 0.5
	end
	return n
end

-- Is a left press at `now` on `url` the second half of a double-click, given
-- the previous press `last` ({ url, t } or nil)? Returns the verdict and the
-- new `last`: nil after a double, so a triple-click starts over instead of
-- firing twice. Pure.
local function click_verdict(last, url, now, interval)
	if last and last.url == url and now - last.t <= interval then
		return true, nil
	end
	return false, { url = url, t = now }
end

-- Finder's mouse contract on the rows: a single click marks (the stock
-- `Entity:click` reveals — moves the cursor there), a double-click acts —
-- enters a folder, opens a file like Enter. Wraps the preset click instead of
-- replacing it, so reveal, right-click-opens and middle-click keep working;
-- `enter`/open act on the row the reveal just hovered (commands apply in emit
-- order). Only inside conspectus, and only if the preset component is where we
-- expect it — a yazi that moved it keeps its stock click behavior.
--
-- Quirk worth knowing: the app delivers its right-click to yazi as a
-- synthesized LEFT click (cursor onto the row before the context menu), so a
-- left click followed within the interval by a right-click on the same row
-- counts as a double-click.
local function install_double_click()
	if type(Entity) ~= "table" or type(Entity.click) ~= "function" then
		ya.notify({ title = "conspectus", timeout = 3, level = "warn",
			content = "double-click not installed — yazi's Entity:click is missing" })
		return
	end
	local base = Entity.click
	local interval = double_click_interval()
	local last = nil
	Entity.click = function(self, event, up)
		base(self, event, up)
		if up or event.is_middle or event.is_right then return end
		local f = self._file
		if not f then return end
		local double
		double, last = click_verdict(last, tostring(f.url), ya.time(), interval)
		if not double then return end
		if f.cha and f.cha.is_dir then
			(ya.emit or ya.mgr_emit)("enter", {})
		else
			open_hovered()
		end
	end
end

-- Cell width of a string. `ui.width` is what yazi measures with itself; the
-- byte-length fallback only matters if a future yazi drops it, and paths are
-- ASCII often enough that it still lands on the right segment.
local function cell_width(s)
	local ok, w = pcall(ui.width, s)
	return ok and w or #s
end

-- Split a path into its non-empty segments.
local function path_segments(s)
	local out = {}
	for seg in s:gmatch("[^/]+") do out[#out + 1] = seg end
	return out
end

-- Which prefix of `cwd` a click at cell offset `rel` into the header's path
-- text addresses — nil for "not on the path" (padding, the flags suffix).
--
-- The header shows `ya.readable_path(cwd)`, i.e. $HOME collapsed to `~`, cut to
-- the free width with rtl = true, so it is the LEFT end that disappears. Both
-- facts point the same way: the visible segments are always a TAIL of the real
-- path, so the mapping counts from the right and never has to know whether `~`
-- swallowed two segments or truncation swallowed five. The one segment that
-- cannot be mapped is a half-eaten first one ("…jects"), and a click there is
-- refused instead of guessed into the wrong directory.
local function breadcrumb_target(text, cwd, rel, truncated)
	local shown, real = path_segments(text), path_segments(cwd)
	if #shown == 0 or #real == 0 then return nil end   -- root has nothing above
	local ends, i = {}, 1
	while true do
		local s, e = text:find("[^/]+", i)
		if not s then break end
		ends[#ends + 1], i = e, e + 1
	end
	local at
	for k = 1, #ends do
		if rel < cell_width(text:sub(1, ends[k])) then
			at = k
			break
		end
	end
	if not at then return nil end
	if truncated and at == 1 then return nil end
	local k = #real - (#shown - at)
	if k < 1 then return nil end
	return "/" .. table.concat(real, "/", 1, k)
end

-- The cwd in the header is a path bar: click a segment to cd there. This is the
-- only mouse route UPWARDS — the columns only ever descend (a click in the
-- parent column enters that sibling directory), so without it "one level up" is
-- keyboard-only. Same convention as Finder's path bar and Explorer's address
-- bar, and it jumps any number of levels in one click.
local function install_breadcrumb_click()
	if type(Header) ~= "table" or type(Header.click) ~= "function" then
		ya.notify({ title = "conspectus", timeout = 3, level = "warn",
			content = "path-bar clicks not installed — yazi's Header:click is missing" })
		return
	end
	local base = Header.click
	Header.click = function(self, event, up)
		base(self, event, up)
		if up or event.is_middle or event.is_right then return end
		local cwd = tostring(self._current.cwd)
		local shown = ya.readable_path(cwd)
		-- The width budget the header computes in redraw — which has not run on
		-- THIS instance: reflow builds a fresh one to route the click through.
		local ok, right = pcall(function() return self:children_redraw(self.RIGHT):width() end)
		local max = self._area.w - (ok and right or 0)
		if max <= 0 then return end
		local text = tostring(ui.truncate(shown, { max = max, rtl = true }))
		local target = breadcrumb_target(text, cwd, event.x - self._area.x, text ~= shown)
		if target then (ya.emit or ya.mgr_emit)("cd", { Url(target) }) end
	end
end

function M:setup()
	-- pcall-guarded env reads in case the yazi sandbox withholds os.getenv.
	local ok, fifo = pcall(function() return os.getenv("QLPEEK_FIFO") end)
	if ok and fifo and #fifo > 0 then
		install_double_click()
		install_breadcrumb_click()
		install_header_gap()
		ps.sub("hover", function()
			local path = get_hovered()
			if not path then return end
			-- Sort first, path second: the app applies the order it last
			-- received when the hover path arrives (lines keep FIFO order).
			local oks, sort = pcall(get_sort)
			if oks then
				fifo_write(fifo, "@SORT:" .. sort)
				fifo_write(fifo, "@LIST_TOP:" .. get_list_top())
			elseif not sort_warned then
				sort_warned = true
				ya.notify({ title = "conspectus", timeout = 5, level = "warn",
					content = "cannot read the sort preference — the folder listing keeps its default order (" .. tostring(sort) .. ")" })
			end
			fifo_write(fifo, path)
			-- A context-menu operation waits for exactly its file to be the
			-- hovered one; any other hover cancels it (never act on a
			-- neighbour because a reveal landed elsewhere).
			if pending_act then
				local act = pending_act
				pending_act = nil
				if act.path == path then
					run_act(act.cmd)
				end
			end
		end)

		-- Yank buffer → app: on every change, announce mode + paths so the
		-- shortcut bar can show WHAT is copied/cut (yazi's own badge only
		-- counts). Empty buffer (Y/X, paste-after-cut) announces too — that
		-- clears the bar. In split mode both panes fire (sync_yanked), the
		-- app receives the same state twice; harmless.
		ps.sub("yank", function()
			local mode = cx.yanked.is_cut and "cut" or "copy"
			local paths = {}
			for _, url in pairs(cx.yanked) do
				paths[#paths + 1] = tostring(url)
			end
			fifo_write(fifo, "@YANK:" .. mode .. ":" .. table.concat(paths, "\t"))
		end)
	end

	local ok2, peer = pcall(function() return os.getenv("CONSPECTUS_PEER") end)
	if ok2 and peer and #peer > 0 then
		local emit = ya.emit or ya.mgr_emit

		-- Tab session: this pane's tab dirs + active index live in the state
		-- file the app hands us (per pane side, shared across app runs), so a
		-- ⌘R theme-restart AND the next app start reopen the same tabs.
		-- Snapshot on every cd — covers navigation and created tabs; a tab
		-- closed after the last cd lingers one round (harmless). Snapshot
		-- failure (API drift) skips the save and never breaks navigation.
		local okf, tabs_file = pcall(function() return os.getenv("CONSPECTUS_TABS_FILE") end)
		if not okf or not tabs_file or #tabs_file == 0 then tabs_file = nil end
		local function save_tabs()
			if not tabs_file then return end
			local ok, lines = pcall(function()
				local t = cx.tabs
				local acc = { tostring(t.idx) }   -- line 1 = active tab (1-based)
				for i = 1, #t do acc[#acc + 1] = tostring(t[i].current.cwd) end
				return acc
			end)
			if not ok then return end
			local f = io.open(tabs_file, "w")
			if f then
				f:write(table.concat(lines, "\n") .. "\n")
				f:close()
			end
		end
		-- Automount: the launcher hands over the mount points from its
		-- automount file ($CONSPECTUS_AUTOMOUNT_DIRS, one per line). A cd into
		-- one of them or below runs `conspectus automount <cwd>`, orphaned so a
		-- slow mount never blocks yazi, at most once per AUTOMOUNT_RECHECK
		-- seconds per mount point; the verdict comes back as
		-- `conspectus-automount` (below). Nothing is reloaded here: yazi
		-- re-lists a remounted cwd by itself (verified with a killed sshfs).
		local oka, am_dirs = pcall(function() return os.getenv("CONSPECTUS_AUTOMOUNT_DIRS") end)
		local okl, launcher = pcall(function() return os.getenv("CONSPECTUS_LAUNCHER") end)
		local mounts = {}
		if oka and am_dirs and okl and launcher and #launcher > 0 then
			for line in am_dirs:gmatch("[^\n]+") do mounts[#mounts + 1] = line end
		end
		local last_check = {}   -- mount point → os.time() when its last check started
		local function automount_check()
			local cwd = tostring(cx.active.current.cwd)
			local hit = nil   -- the longest mount point covering cwd, like the launcher
			for _, mp in ipairs(mounts) do
				if (cwd == mp or cwd:sub(1, #mp + 1) == mp .. "/") and (not hit or #mp > #hit) then
					hit = mp
				end
			end
			if not hit then return end
			local now = os.time()
			if last_check[hit] and now - last_check[hit] < AUTOMOUNT_RECHECK then return end
			last_check[hit] = now
			emit("shell", { ya.quote(launcher) .. " automount " .. ya.quote(cwd), orphan = true })
		end
		if tabs_file or #mounts > 0 then
			ps.sub("cd", function()   -- one handler per event and plugin: both jobs here
				save_tabs()
				if #mounts > 0 then automount_check() end
			end)
		end
		if #mounts > 0 then
			ps.sub_remote("conspectus-automount", function(body)
				if type(body) ~= "string" then return end
				local kind, text = body:match("^(%a+)\t[^\t]*\t(.*)$")
				if not kind then return end
				ya.notify({ title = "automount", timeout = kind == "failed" and 10 or 4,
					level = kind == "failed" and "error" or "info", content = text })
			end)
		end

		-- Restore: the APP decides (CONSPECTUS_TABS_RESTORE) — a start with an
		-- explicit [path] stays clean, a bare start and every ⌘R relaunch
		-- reopen the saved tabs. Tab 1 is cd'd in place, the rest created in
		-- order (tab_create appends after the active tab, so sequential
		-- creation preserves order); tab_switch is 0-based.
		local okr, restore = pcall(function() return os.getenv("CONSPECTUS_TABS_RESTORE") end)
		if tabs_file and okr and restore == "1" then
			local f = io.open(tabs_file, "r")
			if f then
				local idx = tonumber(f:read("l") or "")
				local dirs = {}
				for line in f:lines() do
					if #line > 0 then dirs[#dirs + 1] = line end
				end
				f:close()
				if #dirs > 1 then   -- a single tab is just the normal cwd resume
					-- create-then-cd, NOT tab_create with a path: yazi 26
					-- ignores the positional path (the new tab inherits the
					-- active tab's dir — verified), while a cd right after
					-- always hits the just-created, now-active tab. Commands
					-- apply in emit order.
					emit("cd", { dirs[1] })
					for i = 2, #dirs do
						emit("tab_create", { current = true })
						emit("cd", { dirs[i] })
					end
					if idx and idx >= 1 and idx <= #dirs then
						emit("tab_switch", { idx - 1 })
					end
				end
			end
		end
		-- conspectus-open: show a directory in this window — sent from the
		-- shell (`ya pub-to 0 conspectus-open --str <dir>`, wrapped by the
		-- zsh `con` function). Browser-tab semantics: switch to the tab
		-- already at that dir, else open a new tab there. Left pane only, so
		-- split/triple mode doesn't open the dir twice. Afterwards the
		-- @ACTIVATE sentinel asks the app to bring its window to the front.
		-- Paths are compared as strings (the shell sends a cleaned absolute
		-- path; a mismatch just means a fresh tab, never an error).
		if peer == "L" then
			ps.sub_remote("conspectus-open", function(body)
				if type(body) ~= "string" or #body == 0 then return end
				local okt, idx = pcall(function()
					local t = cx.tabs
					for i = 1, #t do
						if tostring(t[i].current.cwd) == body then return i end
					end
					return 0
				end)
				if okt and idx > 0 then
					emit("tab_switch", { idx - 1 })   -- tab_switch is 0-based
				else
					-- create-then-cd, same reason as the restore above: yazi 26
					-- ignores tab_create's positional path.
					emit("tab_create", { current = true })
					emit("cd", { body })
				end
				if ok and fifo and #fifo > 0 then fifo_write(fifo, "@ACTIVATE") end
			end)
		end
		-- panesync-cd: enter a directory (folder-row click, `=` key).
		ps.sub_remote("panesync-cd", function(body)
			if type(body) == "string" and #body > 0 then
				emit("cd", { body })
			end
		end)
		-- panesync-history: browser-style back/forward — sent by the app for
		-- the mouse's back/forward buttons and the Go menu. The body is
		-- "<direction> <peer>" so only the pane the mouse is over moves in
		-- split mode ("*" addresses both). Runs yazi's own history commands
		-- instead of typing H/L into the pane: a keystroke would land inside
		-- an open filter/search prompt, a command never does.
		ps.sub_remote("panesync-history", function(body)
			if type(body) ~= "string" then return end
			local dir, target = body:match("^(%a+) ([LR*])$")
			if not dir or (target ~= peer and target ~= "*") then return end
			if dir == "back" then
				emit("back", {})
			elseif dir == "forward" then
				emit("forward", {})
			elseif dir == "up" then
				emit("leave", {})
			else
				ya.notify({ title = "conspectus", timeout = 3, level = "warn",
					content = "unknown move direction '" .. dir .. "'" })
			end
		end)
		-- panesync-tab: switch this pane's tabs from the app's Go menu
		-- (⌘⇧[ / ⌘⇧] cycle, ⌘1…⌘9 jump — the tab chord kitty and WezTerm
		-- use). Body is "<move> <peer>" like panesync-history; move is
		-- "prev", "next", or a 1-based tab number. Commands, not keystrokes:
		-- `[` typed into an open filter prompt would land in the query.
		-- These keys exist for the moments a yazi pane does NOT hold the
		-- keyboard (nvim, preview, terminal panel) — with focus in yazi its
		-- own [ / ] / 1…9 do the same thing and never reach the app.
		ps.sub_remote("panesync-tab", function(body)
			if type(body) ~= "string" then return end
			local move, target = body:match("^(%w+) ([LR*])$")
			if not move or (target ~= peer and target ~= "*") then return end
			if move == "prev" then
				emit("tab_switch", { -1, relative = true })
			elseif move == "next" then
				emit("tab_switch", { 1, relative = true })
			else
				-- Absolute jump: 1-based on the wire (⌘3 = third tab),
				-- 0-based in yazi. Out-of-range numbers are yazi's no-op,
				-- same as typing 9 with three tabs open.
				local n = tonumber(move)
				if n and n >= 1 then
					emit("tab_switch", { n - 1 })
				else
					ya.notify({ title = "conspectus", timeout = 3, level = "warn",
						content = "unknown tab move '" .. move .. "'" })
				end
			end
		end)
		-- panesync-reveal: move the cursor onto a path (file-row click) — cds
		-- to its parent and selects it, so the hover sub above previews it.
		ps.sub_remote("panesync-reveal", function(body)
			if type(body) == "string" and #body > 0 then
				emit("reveal", { body })
			end
		end)
		-- panesync-act: the app hands a file operation to yazi instead of
		-- doing it itself — rename and trash (right-click menu) stay yazi's
		-- (one task system, one confirmation, one place that knows the
		-- selection), open (double-click on a listing row) goes through the
		-- shared opener so IDE routing applies; copy/cut/paste and new
		-- file/folder likewise (see run_act). Body
		-- "<peer> <command> <path>". rename/remove run on the
		-- HOVERED item only (`--hovered`), never on a selection the user left
		-- elsewhere — and only once that item IS the path: if it is hovered
		-- already (right-click in this pane), run now; otherwise reveal it
		-- (listing rows live in a child directory) and let the resulting
		-- hover run it (see the hover handler), so a reveal that lands
		-- elsewhere cancels instead of renaming or trashing a neighbour.
		ps.sub_remote("panesync-act", function(body)
			if type(body) ~= "string" then return end
			local target, cmd, path = body:match("^([LR]) (%a+) (.+)$")
			if not target or target ~= peer then return end
			if not act_commands[cmd] then
				ya.notify({ title = "conspectus", timeout = 3, level = "warn",
					content = "unknown context action '" .. cmd .. "'" })
				return
			end
			local ok5, hovered = pcall(function()
				local h = cx.active.current.hovered
				return h and tostring(h.url) or nil
			end)
			if not ok5 then
				ya.notify({ title = "conspectus", timeout = 3, level = "warn",
					content = "context action: cannot read the hovered item — not running " .. cmd })
				return
			end
			if hovered == path then
				run_act(cmd)
			else
				pending_act = { cmd = cmd, path = path }
				emit("reveal", { path })
			end
		end)
		-- panesync-selected (⌘L): answer the app's pull request for this
		-- pane's selection with an @SELECTED FIFO message. Pull, not push —
		-- yazi publishes no event for selection changes, so a live mirror
		-- (like the yank one) is impossible; a snapshot on demand is not.
		-- Body names the pane whose selection is wanted ("L"/"R"); the other
		-- pane stays silent so the app gets exactly one answer.
		ps.sub_remote("panesync-selected", function(body)
			if body ~= peer then return end
			if not (ok and fifo and #fifo > 0) then return end
			local paths = {}
			for _, url in pairs(cx.active.selected) do
				paths[#paths + 1] = tostring(url)
			end
			fifo_write(fifo, "@SELECTED:" .. table.concat(paths, "\t"))
		end)
		-- panesync-restart: quit so the app can relaunch this pane with the
		-- fresh theme — yazi picks its Catppuccin flavor only at startup, so a
		-- light↔dark switch needs a restart to re-flavor. Sent by the app on
		-- every appearance change and on ⌘R, body "<target> <ask|quiet>":
		-- target is a peer ("L"/"R") or "*", so a pane that already restarted
		-- is not bounced again while its sibling is still waiting; "ask" is
		-- the first attempt (a refusal is shown in yazi), "quiet" a retry.
		-- Graceful by contract — NEVER while the pane is in use:
		--   · file tasks running (quitting would abort copies/moves),
		--   · select/unset mode or marked files (a relaunch loses the
		--     selection; the yank buffer survives via the session plugin,
		--     the tabs via ours).
		-- A refusal goes back to the app over the FIFO as
		-- `@RESTART_REFUSED:<peer>:<tasks|selection|error>`, so the shortcut
		-- bar can say what it is waiting for and the app can retry. If the
		-- tasks/mode API ever drifts, fail SAFE: report `error`, don't quit.
		ps.sub_remote("panesync-restart", function(body)
			if type(body) ~= "string" then return end
			local target, how = body:match("^([LR*]) (%a+)$")
			if not target or (target ~= peer and target ~= "*") then return end
			local function refuse(reason, text)
				if ok and fifo and #fifo > 0 then
					fifo_write(fifo, "@RESTART_REFUSED:" .. peer .. ":" .. reason)
				end
				if how == "ask" then
					ya.notify({ title = "conspectus", timeout = 3, level = "warn", content = text })
				end
			end
			-- Busy = tasks announced but not yet finished. Field names drifted
			-- across yazi versions (26.x: summary/success/failed, 25.x:
			-- progress/succ/fail) — try both before giving up.
			local ok3, busy = pcall(function()
				local s = cx.tasks.summary
				return s.total > s.success + s.failed
			end)
			if not ok3 then
				ok3, busy = pcall(function()
					local p = cx.tasks.progress
					return p.total > p.succ + p.fail
				end)
			end
			if not ok3 then
				refuse("error", "theme reload: cannot read task state — not restarting")
				return
			end
			if busy then
				refuse("tasks", "theme reload postponed — file tasks running (retries when idle)")
				return
			end
			-- In use = select/unset mode (v/V) or files marked for a pending
			-- y/x/d. Missing mode fields mean the API drifted — error, never
			-- "not in use".
			local ok4, in_use = pcall(function()
				local m = cx.active.mode
				if m.is_select == nil or m.is_unset == nil then error("tab::Mode fields missing") end
				if m.is_select or m.is_unset then return true end
				for _ in pairs(cx.active.selected) do return true end
				return false
			end)
			if not ok4 then
				refuse("error", "theme reload: cannot read selection state — not restarting")
				return
			end
			if in_use then
				refuse("selection", "theme reload postponed — selection active (retries when cleared)")
				return
			end
			save_tabs()   -- final snapshot: catch tab ops since the last cd
			emit("quit", {})
		end)
	end
end

-- Navigation entry point, in two modes — both decide "directory?" from the
-- HOVERED item, never the selection, so a pending copy/cut can't hijack
-- navigation (a shell `[ -d "$1" ]` test cannot: "$1" is the first SELECTED
-- file). A directory is entered in both modes; they differ on a FILE:
--
--   (no arg)  `l` / `→`: nothing to "enter", so move keyboard focus into the
--             preview pane (`@FOCUS_PREVIEW`; `h`/`←` there returns to yazi).
--   "open"    `o` / `<Enter>`: in IDE mode ($CONSPECTUS_NVIM = the middle
--             nvim's --listen socket) send the selected/hovered text file(s) there
--             as buffers, so several files pile up in one editor; otherwise
--             the normal opener.
--   "lazycvs" `E C`: lazycvs for the hovered item in the app's terminal
--             panel (`lazycvs_hovered` above) — a directory too, so this
--             mode is decided before the enter-a-directory rule.
--
-- Invoked as `ya emit plugin conspectus [open]` from the keymap — note that
-- `ya emit` passes arguments as a list, WITHOUT the `--` separator that the
-- keymap's own `plugin conspectus -- open` form needs (verified: with `--`
-- the argument arrives empty).
function M:entry(job)
	local emit = ya.emit or ya.mgr_emit
	local mode = job and job.args and job.args[1]
	if mode == "lazycvs" then
		lazycvs_hovered()
		return
	end
	if mode ~= nil and mode ~= "" and mode ~= "open" then
		ya.notify({ title = "conspectus", timeout = 3, level = "warn",
			content = "unknown plugin mode '" .. tostring(mode) .. "' — treating it as l/→" })
		mode = nil
	end

	if hovered_is_dir() then
		emit("enter", {})
		return
	end

	if mode == "open" then
		open_hovered()
		return
	end

	local ok, fifo = pcall(function() return os.getenv("QLPEEK_FIFO") end)
	if ok and fifo and #fifo > 0 then
		fifo_write(fifo, "@FOCUS_PREVIEW")
	else
		emit("open", {})
	end
end

return M
