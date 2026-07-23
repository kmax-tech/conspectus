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

return M
