---crude.nvim provider for Perforce changelists.
---
---Register it yourself:
---  require("crude").register_provider("perforce", require("perforce.plugins.crude.provider"))
---  require("crude").register_provider("perforce", require("perforce.plugins.crude.provider")({ delete_action = "revert" }))
local perforce = require("perforce")
local p4 = require("perforce.plugins.crude.p4")
local url_mod = require("perforce.plugins.crude.url")

local M = {}

---@class perforce.crude.ProviderOptions
---@field history_max? integer Number of changelists listed in p4://history (default 50)
---@field delete_action? "revert_keep"|"revert"|"disabled" What deleting a line in a changelist buffer does (default "revert_keep")

local HIGHLIGHTS = {
	PerforceCrudeUser = "Identifier",
	PerforceCrudeChange = "Number",
	PerforceCrudeDefault = "Special",
	PerforceCrudeCount = "Comment",
	PerforceCrudeDescription = "Comment",
	PerforceCrudeStatusPending = "DiagnosticWarn",
	PerforceCrudeStatusSubmitted = "Comment",
	PerforceCrudeStatusShelved = "DiagnosticInfo",
	PerforceCrudeActionEdit = "Changed",
	PerforceCrudeActionAdd = "Added",
	PerforceCrudeActionDelete = "Removed",
	PerforceCrudeActionMove = "Changed",
	PerforceCrudeActionIntegrate = "Special",
}

local function set_highlights()
	for name, link in pairs(HIGHLIGHTS) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("perforce-crude-provider-hl", { clear = true }),
	callback = set_highlights,
})

---@type table<string, string>
local ACTION_HL = {
	edit = "PerforceCrudeActionEdit",
	add = "PerforceCrudeActionAdd",
	branch = "PerforceCrudeActionAdd",
	import = "PerforceCrudeActionAdd",
	delete = "PerforceCrudeActionDelete",
	["move/delete"] = "PerforceCrudeActionDelete",
	purge = "PerforceCrudeActionDelete",
	archive = "PerforceCrudeActionDelete",
	["move/add"] = "PerforceCrudeActionMove",
	integrate = "PerforceCrudeActionIntegrate",
}

local STATUS_HL = {
	pending = "PerforceCrudeStatusPending",
	submitted = "PerforceCrudeStatusSubmitted",
	shelved = "PerforceCrudeStatusShelved",
}

---First non-empty line of a changelist description
---@param desc string?
---@return string
local function first_line(desc)
	for _, line in ipairs(vim.split(desc or "", "\n", { plain = true })) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			return trimmed
		end
	end
	return ""
end

---Sort changelists: "default" first, then numeric descending (newest first)
---@param a string
---@param b string
---@return boolean
local function changelist_lt(a, b)
	if a == "default" or b == "default" then
		return a == "default" and b ~= "default"
	end
	local na, nb = tonumber(a), tonumber(b)
	if na and nb then
		return na > nb
	end
	return a < b
end
M.changelist_lt = changelist_lt

---Whether bufnr is a buffer owned by a perforce crude provider
---@param bufnr? integer
---@return boolean
local function is_perforce_buf(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local ok, crude = pcall(require, "crude")
	if ok and crude.get_provider then
		local prov = crude.get_provider(bufnr)
		if type(prov) == "table" and prov._perforce == true then
			return true
		end
	end
	return url_mod.try_parse(vim.api.nvim_buf_get_name(bufnr)) ~= nil
end
M.is_perforce_buf = is_perforce_buf

---Whether a changelist buffer was loaded as read-only (submitted / another client's changelist)
---@param bufnr integer
---@return boolean
function M.is_readonly(bufnr)
	return vim.b[bufnr].perforce_crude_readonly == true
end

---Schedule a navigation outside of crude's async task, optionally focusing an entry afterwards
---@param target string
---@param focus? string
local function navigate(target, focus)
	vim.schedule(function()
		local win = vim.api.nvim_get_current_win()
		vim.cmd.edit(vim.fn.fnameescape(target))
		if focus and focus ~= "" then
			local ok, crude = pcall(require, "crude")
			if ok and crude.focus_entry then
				pcall(crude.focus_entry, win, focus)
			end
		end
	end)
end

local is_windows = vim.fn.has("win32") == 1

---Normalized lookup key for a local path (case-insensitive on Windows)
---@param path string
---@return string
local function path_key(path)
	local p = vim.fs.normalize(path):gsub("/+$", "")
	return is_windows and p:lower() or p
end

---Convert a `p4 opened` clientFile (`//<client>/<rel>` or a local path) to a local path
---@param client_file? string
---@param info? table p4 info
---@return string?
local function client_to_local(client_file, info)
	if type(client_file) ~= "string" or client_file == "" then
		return nil
	end
	if not client_file:match("^//") then
		return client_file
	end
	if not info or not info.clientName or not info.clientRoot or info.clientRoot == "" or info.clientRoot == "null" then
		return nil
	end
	local prefix = "//" .. info.clientName .. "/"
	if client_file:sub(1, #prefix):lower() ~= prefix:lower() then
		return nil
	end
	-- p4 escapes @ # % * in paths as %40 %23 %25 %2A
	local rel = client_file:sub(#prefix + 1):gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)
	return info.clientRoot .. "/" .. rel
end

-- Focus on open ----------------------------------------------------------------
-- `:edit p4://...` from a file focuses that file (changelist buffers) or the changelist it's opened in (overviews).
-- `:edit p4://` from `p4://<cl>` focuses that changelist.

---bufnr -> { [path_key(local file)] = entry name }, rebuilt on every list
---@type table<integer, table<string, string>>
local local_index = {}

---bufnr -> { win, from } waiting for the buffer to finish loading
---@type table<integer, { win: integer, from: integer }>
local pending_focus = {}

---Entry name to focus in bufnr when arriving from from_buf
---@param bufnr integer
---@param from_buf integer
---@return string?
local function focus_target(bufnr, from_buf)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_valid(from_buf) or bufnr == from_buf then
		return nil
	end
	local url = url_mod.try_parse(vim.api.nvim_buf_get_name(bufnr))
	if not url then
		return nil
	end
	local from_name = vim.api.nvim_buf_get_name(from_buf)
	local from_url = url_mod.try_parse(from_name)
	if from_url then
		if from_url.kind == "changelist" and url.kind ~= "changelist" then
			return from_url.changelist
		end
		return nil
	end
	if from_name == "" or vim.bo[from_buf].buftype ~= "" then
		return nil
	end
	local index = local_index[bufnr]
	return index and index[path_key(from_name)]
end

---@param bufnr integer
---@param win integer
---@param from integer
local function apply_focus(bufnr, win, from)
	if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
		return
	end
	local target = focus_target(bufnr, from)
	if not target then
		return
	end
	local ok, crude = pcall(require, "crude")
	if ok and crude.focus_entry then
		pcall(crude.focus_entry, win, target)
	end
end

local focus_group = vim.api.nvim_create_augroup("perforce-crude-focus", { clear = true })

vim.api.nvim_create_autocmd("BufWinEnter", {
	group = focus_group,
	pattern = "p4://*",
	callback = function(ev)
		local from = vim.fn.bufnr("#")
		if from <= 0 then
			return
		end
		local win = vim.api.nvim_get_current_win()
		if local_index[ev.buf] then
			apply_focus(ev.buf, win, from)
		else
			pending_focus[ev.buf] = { win = win, from = from }
		end
	end,
})

vim.api.nvim_create_autocmd("User", {
	group = focus_group,
	pattern = "CrudeLoaded",
	callback = function(ev)
		local bufnr = ev.data and ev.data.bufnr
		local pending = bufnr and pending_focus[bufnr]
		if pending then
			pending_focus[bufnr] = nil
			apply_focus(bufnr, pending.win, pending.from)
		end
	end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
	group = focus_group,
	pattern = "p4://*",
	callback = function(ev)
		local_index[ev.buf] = nil
		pending_focus[ev.buf] = nil
	end,
})

-- Columns -------------------------------------------------------------------

local function col_value(entry, name)
	return entry.columns and entry.columns[name]
end

local user_col = {
	name = "user",
	title = "USER",
	render = function(entry)
		return col_value(entry, "user") or "", "PerforceCrudeUser"
	end,
}

local files_col = {
	name = "files",
	title = "FILES",
	align = "right",
	render = function(entry)
		local n = col_value(entry, "files")
		return n and tostring(n) or "", "PerforceCrudeCount"
	end,
}

local status_col = {
	name = "status",
	title = "STATUS",
	render = function(entry)
		local s = col_value(entry, "status") or ""
		return s, STATUS_HL[s]
	end,
}

local change_name_col = {
	name = "name",
	is_name = true,
	title = "CHANGE",
	render = function(entry)
		return entry.name, entry.name == "default" and "PerforceCrudeDefault" or "PerforceCrudeChange"
	end,
}

local description_col = {
	name = "description",
	title = "DESCRIPTION",
	render = function(entry)
		return col_value(entry, "description") or "", "PerforceCrudeDescription"
	end,
}

local action_col = {
	name = "action",
	title = "ACTION",
	render = function(entry)
		local act = col_value(entry, "action") or ""
		return act, ACTION_HL[act]
	end,
}

local file_name_col = {
	name = "name",
	is_name = true,
	title = "FILE",
}

M.column_sets = {
	pending = { user_col, files_col, change_name_col, description_col },
	opened = { user_col, files_col, change_name_col, description_col },
	history = { user_col, status_col, change_name_col, description_col },
	changelist = { action_col, file_name_col },
}

---@param bufnr? integer
---@return crude.ColumnDef[]?
function M.columns(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local url = url_mod.try_parse(vim.api.nvim_buf_get_name(bufnr))
	return url and M.column_sets[url.kind] or nil
end

-- Listing -------------------------------------------------------------------

---@param kind string
---@param cl string
---@param columns table
---@param meta? table
---@return crude.Entry
local function changelist_entry(kind, cl, columns, meta)
	return {
		id = kind .. ":" .. cl,
		name = cl,
		columns = columns,
		meta = vim.tbl_extend("force", { type = "changelist", changelist = cl }, meta or {}),
	}
end

---@param opts perforce.crude.ProviderOptions
---@return crude.Entry[]
local function list_history(opts)
	local changes = p4.query(perforce.changes, { max = opts.history_max, full_description = true })
	local entries = {}
	for _, ch in ipairs(changes) do
		local cl = tostring(ch.change)
		table.insert(
			entries,
			changelist_entry("history", cl, {
				user = ch.user or "",
				status = ch.status or "",
				description = first_line(ch.desc),
			}, { status = ch.status, user = ch.user, client = ch.client })
		)
	end
	table.sort(entries, function(a, b)
		return changelist_lt(a.name, b.name)
	end)
	return entries
end

---@param kind "pending"|"opened"
---@return crude.Entry[] rows
---@return table<string, string> index path_key(local file) -> changelist
local function list_mine(kind)
	local info = p4.client_info()
	assert(info, "[perforce] Could not determine the Perforce client (p4 info failed)")

	local counts = {}
	local index = {}
	for _, item in ipairs(p4.query(perforce.opened, {})) do
		local cl = item.change or "default"
		counts[cl] = (counts[cl] or 0) + 1
		local path = client_to_local(item.clientFile, info)
		if path then
			index[path_key(path)] = cl
		end
	end

	local pending = p4.query(perforce.changes, {
		status = "pending",
		user = info.userName,
		client = info.clientName,
		full_description = true,
	})

	local rows = {}
	local seen = {}
	local function add(cl, user, desc)
		if seen[cl] then
			return
		end
		if kind == "opened" and not counts[cl] then
			return
		end
		seen[cl] = true
		table.insert(
			rows,
			changelist_entry(kind, cl, {
				user = user or info.userName or "",
				files = counts[cl],
				description = desc or "",
			}, { user = user, count = counts[cl] })
		)
	end

	add("default", info.userName, "Default changelist")
	for _, ch in ipairs(pending) do
		add(tostring(ch.change), ch.user, first_line(ch.desc))
	end
	-- Changelists with opened files that `p4 changes` didn't report (e.g. restricted)
	for cl in pairs(counts) do
		add(cl, info.userName, "")
	end

	table.sort(rows, function(a, b)
		return changelist_lt(a.name, b.name)
	end)
	return rows, index
end

---@param bufnr integer
---@param cl string
---@return crude.Entry[] entries
---@return table<string, string> index path_key(local file) -> depot path (entry name)
local function list_changelist(bufnr, cl)
	local function file_entry(item, readonly, local_file)
		assert(type(item.depotFile) == "string" and item.depotFile ~= "", "[perforce] file record without depotFile")
		return {
			id = cl .. ":" .. item.depotFile,
			name = item.depotFile,
			columns = { action = item.action or "" },
			meta = {
				type = "file",
				changelist = cl,
				depot_file = item.depotFile,
				client_file = item.clientFile,
				local_file = local_file,
				action = item.action,
				rev = item.rev,
				filetype = item.type,
				submitted = readonly,
			},
		}
	end

	local entries = {}
	local index = {}
	local opened = p4.query(perforce.opened, { changelist = cl })
	if #opened > 0 then
		vim.b[bufnr].perforce_crude_readonly = false
		local info = p4.client_info()
		for _, item in ipairs(opened) do
			local path = client_to_local(item.clientFile, info)
			if path then
				path = vim.fs.normalize(path)
				index[path_key(path)] = item.depotFile
			end
			table.insert(entries, file_entry(item, false, path))
		end
		return entries, index
	end

	if cl == "default" then
		vim.b[bufnr].perforce_crude_readonly = false
		return entries, index
	end

	-- Not opened in this client: describe it (submitted, shelved, empty pending, or another client's changelist)
	local errors, desc = p4.call(perforce.describe, cl)
	if type(desc) ~= "table" then
		error(p4.error_message(errors, nil) or string.format("[perforce] Changelist %s not found", cl), 0)
	end
	local info = p4.client_info()
	local readonly = desc.status ~= "pending" or (info ~= nil and desc.client ~= nil and desc.client ~= info.clientName)
	vim.b[bufnr].perforce_crude_readonly = readonly
	for _, item in ipairs(desc.files or {}) do
		table.insert(entries, file_entry(item, readonly))
	end
	return entries, index
end

-- Applying ------------------------------------------------------------------

---Open `name` (depot or local path) into changelist `cl`: reopen if already opened, edit if it exists in the
---depot, add otherwise.
---@param cl string
---@param name string
---@return string? err
local function open_into(cl, name)
	local _, fstat_res = p4.call(perforce.fstat, {
		files = { name },
		fields = { "depotFile", "clientFile", "headAction", "headRev", "action", "change" },
	})
	local rec = p4.records(fstat_res)[1]

	local errors, res
	if rec and rec.action then
		if rec.change == cl then
			return nil
		end
		errors, res = p4.call(perforce.reopen, { changelist = cl, files = { name } })
	elseif rec and rec.headRev and not tostring(rec.headAction or ""):match("delete") then
		errors, res = p4.call(perforce.edit, { changelist = cl, files = { name } })
	else
		local path = name
		if name:match("^//") then
			path = (rec and rec.clientFile) or p4.local_path(name)
			if not path then
				return string.format("[perforce] Cannot resolve a local path for '%s' (not in client view?)", name)
			end
		end
		errors, res = p4.call(perforce.add, { changelist = cl, files = { path } })
	end
	return p4.error_message(errors, res)
end

---Reject wildcards and revision specifiers that would make p4 act on more than the typed file
---@param name string
---@return boolean ok
---@return string? err
local function validate_file_name(name)
	if name:find("...", 1, true) or name:find("*", 1, true) or name:find("%", 1, true) then
		return false, "Wildcards (..., *, %) are not allowed in changelist buffers"
	end
	if name:find("[#@]") then
		return false, "Revision specifiers (#, @) are not allowed in changelist buffers"
	end
	if name:match("^//[^/]") or name:match("^%a:[/\\]") or name:match("^/") or name:match("^%.%.?[/\\]") then
		return true
	end
	return false, "Expected a depot path (//depot/...) or a local file path"
end

---@param opts? perforce.crude.ProviderOptions
---@return crude.Provider
function M.create(opts)
	opts = vim.tbl_extend("force", {
		history_max = 50,
		delete_action = "revert_keep",
	}, opts or {})
	assert(
		opts.delete_action == "revert_keep" or opts.delete_action == "revert" or opts.delete_action == "disabled",
		"delete_action must be 'revert_keep', 'revert', or 'disabled'"
	)
	assert(type(opts.history_max) == "number" and opts.history_max > 0, "history_max must be a positive number")

	---changelist -> overview url it was opened from (for `-`)
	---@type table<string, string>
	local parent_by_cl = {}

	---@type crude.Provider
	local prov = {
		_perforce = true,
		options = opts,
		patterns = { "p4://*" },
		columns = M.columns,

		list = function(bufnr)
			local url = url_mod.parse(vim.api.nvim_buf_get_name(bufnr))
			local entries, index
			if url.kind == "history" then
				vim.b[bufnr].perforce_crude_readonly = true
				entries = list_history(opts)
			elseif url.kind == "pending" or url.kind == "opened" then
				vim.b[bufnr].perforce_crude_readonly = true
				entries, index = list_mine(url.kind)
			else
				entries, index = list_changelist(bufnr, url.changelist)
			end
			local_index[bufnr] = index or {}
			return entries
		end,

		validate_entry_name = function(name, bufnr)
			local url = url_mod.try_parse(vim.api.nvim_buf_get_name(bufnr))
			if not url or url.kind ~= "changelist" then
				return true
			end
			return validate_file_name(name)
		end,

		apply = function(bufnr, diffs, ctx)
			local url = url_mod.parse(vim.api.nvim_buf_get_name(bufnr))

			local function fail(item, msg)
				if ctx then
					ctx:report_error(item, msg)
				else
					error(msg, 0)
				end
			end
			local function progress(item, msg)
				if ctx then
					ctx:report_progress(item, msg)
				end
			end
			local function done(item)
				if ctx then
					ctx:report_done(item)
				end
			end

			if url.kind ~= "changelist" or M.is_readonly(bufnr) then
				local msg = url.kind ~= "changelist"
						and "[perforce] Changelist overview buffers are read-only; edit files inside a p4://<changelist> buffer"
					or string.format("[perforce] Changelist %s is read-only (submitted or owned by another client)", url.changelist)
				local reported = false
				for _, list in ipairs({ diffs.deletes, diffs.renames, diffs.creates, diffs.column_changes }) do
					for _, item in ipairs(list or {}) do
						fail(item, msg)
						reported = true
					end
				end
				if not reported then
					fail(nil, msg)
				end
				return
			end

			local cl = url.changelist
			local changed = false

			-- 1. Deletions: revert (or hand off to the destination buffer for cross-buffer moves)
			for _, del in ipairs(diffs.deletes or {}) do
				local depot = (del.entry and del.entry.meta and del.entry.meta.depot_file) or del.name
				if del.is_move then
					if is_perforce_buf(del.dest_bufnr) then
						-- The destination changelist buffer reopens the file
						done(del)
					else
						fail(del, "[perforce] Perforce files can only be moved into other p4://<changelist> buffers")
					end
				elseif opts.delete_action == "disabled" then
					fail(del, "[perforce] Removing files from a changelist is disabled (delete_action = 'disabled')")
				else
					progress(del, "reverting " .. depot)
					local errors, res = p4.call(perforce.revert, {
						changelist = cl,
						files = { depot },
						keep_workspace_files = opts.delete_action == "revert_keep",
					})
					local msg = p4.error_message(errors, res)
					if msg then
						fail(del, msg)
					else
						changed = true
						done(del)
					end
				end
			end

			-- 2. Renames: p4 move
			for _, ren in ipairs(diffs.renames or {}) do
				local from = (ren.entry and ren.entry.meta and ren.entry.meta.depot_file) or ren.from
				progress(ren, string.format("moving %s -> %s", from, ren.to))
				local errors, res = p4.call(perforce.move, { changelist = cl, from_file = from, to_file = ren.to })
				local msg = p4.error_message(errors, res)
				if msg then
					fail(ren, msg)
				else
					changed = true
					done(ren)
				end
			end

			-- 3. Creations: reopen (cross-buffer move), or edit/add typed paths
			for _, cr in ipairs(diffs.creates or {}) do
				if cr.is_move then
					if not is_perforce_buf(cr.src_bufnr) then
						fail(cr, "[perforce] Only entries cut from other p4://<changelist> buffers can be moved here")
					else
						local src_entry = cr.src_entry or (cr.src_delete and cr.src_delete.entry)
						local depot = (src_entry and src_entry.meta and src_entry.meta.depot_file)
							or (cr.src_delete and cr.src_delete.name)
							or cr.src_name
							or cr.name
						progress(cr, string.format("reopening %s in %s", depot, cl))
						local errors, res = p4.call(perforce.reopen, { changelist = cl, files = { depot } })
						local msg = p4.error_message(errors, res)
						if not msg and cr.name ~= depot then
							progress(cr, string.format("moving %s -> %s", depot, cr.name))
							errors, res = p4.call(perforce.move, { changelist = cl, from_file = depot, to_file = cr.name })
							msg = p4.error_message(errors, res)
						end
						if msg then
							fail(cr, msg)
						else
							changed = true
							done(cr)
						end
					end
				elseif cr.is_copy then
					fail(cr, "[perforce] A file can only be open in one changelist; cut (dd) instead of yank (yy) to move it")
				else
					progress(cr, string.format("opening %s in %s", cr.name, cl))
					local msg = open_into(cl, cr.name)
					if msg then
						fail(cr, msg)
					else
						changed = true
						done(cr)
					end
				end
			end

			if changed then
				p4.emit_opened_changed({ changelist = cl })
			end
		end,

		on_select = function(entry, bufnr)
			local url = url_mod.parse(vim.api.nvim_buf_get_name(bufnr))
			if url.kind ~= "changelist" then
				local cl = (entry.meta and entry.meta.changelist) or entry.name
				parent_by_cl[cl] = url_mod.format(url)
				navigate(url_mod.changelist(cl))
				return
			end

			local meta = entry.meta or {}
			local depot = meta.depot_file or entry.name
			if not meta.submitted then
				local path = p4.local_path(depot)
				if path and vim.uv.fs_stat(path) then
					navigate(path)
					return
				end
			end

			-- Not on disk (submitted, deleted, or not synced): show the depot revision read-only
			local spec = depot:match("^//") and (depot .. (meta.rev and ("#" .. meta.rev) or "")) or depot
			local errors, content = p4.call(perforce.print, { file = spec })
			if type(content) ~= "string" or content == "" then
				vim.notify(
					string.format("[perforce] Could not print %s: %s", spec, p4.error_message(errors, nil) or "empty"),
					vim.log.levels.WARN
				)
				return
			end
			vim.schedule(function()
				local name = "p4-print://" .. spec:gsub("^//", "")
				local buf = vim.fn.bufnr(name)
				if buf == -1 then
					buf = vim.api.nvim_create_buf(true, true)
					pcall(vim.api.nvim_buf_set_name, buf, name)
				end
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\r?\n"))
				vim.bo[buf].buftype = "nofile"
				vim.bo[buf].bufhidden = "hide"
				vim.bo[buf].modifiable = false
				vim.bo[buf].readonly = true
				local ft = vim.filetype.match({ buf = buf, filename = vim.fs.basename(depot) })
				if ft then
					vim.bo[buf].filetype = ft
				end
				vim.api.nvim_set_current_buf(buf)
			end)
		end,

		on_parent = function(bufnr)
			local url = url_mod.parse(vim.api.nvim_buf_get_name(bufnr))
			if url.kind == "changelist" then
				navigate(parent_by_cl[url.changelist] or url_mod.scheme, url.changelist)
			elseif url.kind == "pending" then
				local info = p4.client_info()
				if not info or not info.clientRoot or info.clientRoot == "" or info.clientRoot == "null" then
					vim.notify("[perforce] Could not determine the workspace root", vim.log.levels.WARN)
					return
				end
				navigate(vim.fs.normalize(info.clientRoot))
			else
				navigate(url_mod.scheme)
			end
		end,
	}

	---Exposed for tests
	prov._parent_by_cl = parent_by_cl

	return prov
end

local default_instance = M.create()
for k, v in pairs(default_instance) do
	M[k] = v
end

return setmetatable(M, {
	__call = function(_, opts)
		return M.create(opts)
	end,
})
