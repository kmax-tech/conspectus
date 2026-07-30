-- conspectus.yazi — bundled glue between yazi and the conspectus app.
-- Shipped inside the conspectus repo and injected into the overlay config by
-- bin/conspectus; the user's own yazi config is never touched, and no
-- external binaries are needed.
--
-- Two jobs:
--   1. Preview coupling: every hover writes the hovered path to the FIFO the
--      app hands us via $QLPEEK_FIFO. Written directly from Lua — the app
--      holds the FIFO open read-write for its whole lifetime, so opening it
--      for append returns immediately (a FIFO open-for-write only blocks
--      when no reader exists, and yazi dies with the app anyway).
--   2. panesync: follow `panesync-cd` DDS broadcasts with a cd — sent by the
--      app when a folder row in the preview listing is clicked, or by the
--      user's `=` key. Guarded by $CONSPECTUS_PEER, which only conspectus
--      sets, so a plain terminal yazi never follows.

local M = {}

local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	return h and tostring(h.url) or nil
end)

-- Whether the item UNDER THE CURSOR is a directory — read from yazi's real
-- state, so it's correct even with files selected (unlike a shell `[ -d "$1" ]`
-- test, where "$1" is the first SELECTED file, not the hovered one).
local hovered_is_dir = ya.sync(function()
	local h = cx.active.current.hovered
	return h ~= nil and h.cha.is_dir
end)

function M:setup()
	-- pcall-guarded env reads in case the yazi sandbox withholds os.getenv.
	local ok, fifo = pcall(function() return os.getenv("QLPEEK_FIFO") end)
	if ok and fifo and #fifo > 0 then
		ps.sub("hover", function()
			local path = get_hovered()
			if not path then return end
			local f = io.open(fifo, "a")
			if f then
				f:write(path .. "\n")
				f:close()
			end
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
		if tabs_file then
			ps.sub("cd", save_tabs)
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
		-- panesync-cd: enter a directory (folder-row click, `=` key).
		ps.sub_remote("panesync-cd", function(body)
			if type(body) == "string" and #body > 0 then
				emit("cd", { body })
			end
		end)
		-- panesync-reveal: move the cursor onto a path (file-row click) — cds
		-- to its parent and selects it, so the hover sub above previews it.
		ps.sub_remote("panesync-reveal", function(body)
			if type(body) == "string" and #body > 0 then
				emit("reveal", { body })
			end
		end)
		-- panesync-restart (⌘R): quit so the app can relaunch this pane with
		-- the fresh theme — yazi picks its Catppuccin flavor only at startup,
		-- so a live light↔dark switch needs a restart to re-flavor. Graceful
		-- by contract: NEVER with file tasks running (quitting would abort
		-- copies/moves) — then just say so and stay alive; the app's restart
		-- window simply expires. If the tasks API ever drifts, fail SAFE:
		-- report and don't quit.
		ps.sub_remote("panesync-restart", function(_)
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
				ya.notify({ title = "conspectus", timeout = 3, level = "warn",
					content = "theme reload: cannot read task state — not restarting" })
				return
			end
			if busy then
				ya.notify({ title = "conspectus", timeout = 3, level = "warn",
					content = "theme reload postponed — file tasks running (⌘R again when idle)" })
				return
			end
			save_tabs()   -- final snapshot: catch tab ops since the last cd
			emit("quit", {})
		end)
	end
end

-- `l` / `→` inside conspectus: enter the hovered directory, or — on a file,
-- where there's nothing to enter — move keyboard focus into the preview pane
-- (the `@FOCUS_PREVIEW` sentinel; `h`/`←` there returns to yazi). Decided from
-- the HOVERED item, never the selection, so a pending copy/cut can't hijack
-- navigation. Invoked as `ya emit plugin conspectus` from the keymap.
function M:entry(job)
	local emit = ya.emit or ya.mgr_emit
	if hovered_is_dir() then
		emit("enter", {})
		return
	end
	local ok, fifo = pcall(function() return os.getenv("QLPEEK_FIFO") end)
	if ok and fifo and #fifo > 0 then
		local f = io.open(fifo, "a")
		if f then
			f:write("@FOCUS_PREVIEW\n")
			f:close()
		end
	else
		emit("open", {})
	end
end

return M
