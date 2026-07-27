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
