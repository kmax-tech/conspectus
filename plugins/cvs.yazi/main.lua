--- @since 26.5.6
-- cvs.yazi — CVS status signs in yazi's file list, the way git.yazi shows
-- git's. Bundled with conspectus and injected by bin/conspectus (fetcher
-- entries appended to the overlay yazi.toml, setup in the overlay init.lua).
--
-- A fetcher: yazi calls `fetch` asynchronously for the files of every
-- directory it shows. Outside a CVS checkout (no `CVS/Entries`) it does
-- nothing and spawns nothing. Inside, it runs `$CONSPECTUS_BIN --cvs-status
-- <dir>` — the status logic lives once, in ConspectusCore (CVS.swift), and
-- the pane's folder listing uses the same code. Offline: Entries + mtimes +
-- cvsignore — plus a second, server-side phase below.
--
-- Signs are the letters `cvs -n update` prints: M modified, A added,
-- R removed, C conflict, ? unknown; clean and ignored files get a blank
-- placeholder so the column stays aligned inside a checkout.
--
-- Second phase, same fetch: `--cvs-remote <dir>` asks the server (one
-- `cvs -n -q update -l`, ~0.25 s over a kept-alive ssh connection, cached
-- for CONSPECTUS_CVS_REMOTE seconds) and overlays `U` on the files the
-- server has newer revisions of — the answer to "am I looking at the
-- current version?". The local signs are already on screen while that
-- runs. A failed check (server unreachable) is reported once per session.

local SIGNS = { modified = "M", added = "A", removed = "R", conflict = "C", unknown = "?",
	["needs-update"] = "U" }

-- Statuses of one directory, keyed by entry name; replaces what was there.
local add = ya.sync(function(st, dir, statuses)
	st.dirs[dir] = statuses
	ui.render()
end)

-- Overlay the server's answer on a directory still on record (a directory
-- left meanwhile has been removed; nothing to overlay then).
local add_remote = ya.sync(function(st, dir, names)
	local statuses = st.dirs[dir]
	if not statuses then
		return
	end
	for _, name in ipairs(names) do
		statuses[name] = "needs-update"
	end
	ui.render()
end)

-- The first failed server check of this yazi session is shown; later ones
-- are not (a dead VPN would otherwise nag on every directory). Returns
-- whether to notify.
local first_remote_error = ya.sync(function(st)
	if st.remote_error_shown then
		return false
	end
	st.remote_error_shown = true
	return true
end)

-- Forget a directory that is (no longer) a checkout.
local remove = ya.sync(function(st, dir)
	if st.dirs[dir] then
		st.dirs[dir] = nil
		ui.render()
	end
end)

local function setup(st, opts)
	st.dirs = {}
	opts = opts or {}
	local styles = {
		modified = ui.Style():fg("yellow"),
		added = ui.Style():fg("green"),
		removed = ui.Style():fg("red"),
		conflict = ui.Style():fg("red"):bold(),
		unknown = ui.Style():fg("magenta"),
		["needs-update"] = ui.Style():fg("blue"),
	}

	Linemode:children_add(function(self)
		if not self._file.in_current then
			return ""
		end
		local url = self._file.url
		local dir = tostring(url.base or url.parent)
		local statuses = st.dirs[dir]
		if not statuses then
			return "" -- not a checkout (or not fetched yet): no column at all
		end
		local code = statuses[tostring(url):sub(#dir + 2)]
		local sign = code and SIGNS[code]
		if not sign then
			return "  "
		elseif self._file.is_hovered then
			return ui.Line { " ", sign }
		else
			return ui.Line { " ", ui.Span(sign):style(styles[code]) }
		end
	end, opts.order or 1600)
end

local function fetch(_, job)
	local cwd = job.files[1].url.base or job.files[1].url.parent
	local dir = tostring(cwd)
	if not fs.cha(cwd:join("CVS"):join("Entries")) then
		remove(dir)
		return true
	end

	local bin = os.getenv("CONSPECTUS_BIN")
	if not bin then
		return true, Err("cvs.yazi: CONSPECTUS_BIN is unset — start yazi through bin/conspectus")
	end
	local output, err = Command(bin):arg({ "--cvs-status", dir }):output()
	if not output then
		return true, Err("cvs.yazi: cannot spawn `%s`, error: %s", bin, err)
	end
	if not output.status.success then
		return true, Err("cvs.yazi: `%s --cvs-status` failed: %s", bin, output.stderr)
	end
	if output.stderr ~= "" then
		-- Malformed Entries lines: the signs still come, but say so.
		ya.notify { title = "cvs.yazi", content = output.stderr, timeout = 5, level = "warn" }
	end

	local statuses = {}
	for line in output.stdout:gmatch("[^\n]+") do
		local code, name = line:match("^(%a+)\t(.+)$")
		if not code then
			return true, Err("cvs.yazi: unexpected --cvs-status line: %s", line)
		end
		statuses[name] = code
	end
	add(dir, statuses)

	-- Phase two: the server. Blocks only this fetcher thread; the local
	-- signs above are already rendered.
	local remote, rerr = Command(bin):arg({ "--cvs-remote", dir }):output()
	if not remote then
		return true, Err("cvs.yazi: cannot spawn `%s --cvs-remote`, error: %s", bin, rerr)
	end
	if not remote.status.success then
		return true, Err("cvs.yazi: `%s --cvs-remote` failed: %s", bin, remote.stderr)
	end
	local names = {}
	for line in remote.stdout:gmatch("[^\n]+") do
		local field, value = line:match("^([%w%-]+)\t(.*)$")
		if field == "needs-update" then
			names[#names + 1] = value
		elseif field == "error" then
			if first_remote_error() then
				ya.notify { title = "cvs.yazi", content = "server check failed — no U signs: " .. value,
					timeout = 6, level = "warn" }
			end
		elseif field ~= "checked" then
			return true, Err("cvs.yazi: unexpected --cvs-remote line: %s", line)
		end
	end
	add_remote(dir, names)
	-- false: not cached, so the next fetch (files changed, re-entered) refreshes.
	return false
end

return { setup = setup, fetch = fetch }
