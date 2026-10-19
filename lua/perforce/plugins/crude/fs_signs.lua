---crude.nvim extension: sign column marks in `crude-fs` buffers for files opened in your Perforce workspace.
---
---Register it yourself:
---  require("crude").register_extension("crude-fs-p4", require("perforce.plugins.crude.fs_signs"))
---  require("crude").register_extension("crude-fs-p4", require("perforce.plugins.crude.fs_signs")({ propagate_dir_status = false }))
---
---Signs refresh whenever the crude-fs buffer (re)loads, on `User PerforceOpenedChanged` (fired after saving p4://
---changelist buffers and change specs), and on FocusGained (to pick up p4 commands run outside Neovim).
local perforce = require("perforce")

local M = {}

---@class perforce.crude.FsSign
---@field text? string 1-2 characters ("" disables the sign)
---@field hl? string highlight group

---@class perforce.crude.FsSignsOptions
---@field providers? string[] crude provider ids to attach to (default { "crude-fs", "fs" })
---@field propagate_dir_status? boolean mark directories containing opened files (default true)
---@field refresh_on_focus? boolean refresh on FocusGained (default true)
---@field priority? integer sign extmark priority (default 20)
---@field signs? table<"edit"|"add"|"delete"|"move"|"integrate"|"dir", perforce.crude.FsSign>

local HIGHLIGHTS = {
	PerforceSignEdit = "Changed",
	PerforceSignAdd = "Added",
	PerforceSignDelete = "Removed",
	PerforceSignMove = "Changed",
	PerforceSignIntegrate = "Special",
	PerforceSignDir = "Changed",
}

local function set_highlights()
	for name, link in pairs(HIGHLIGHTS) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("perforce-crude-fs-signs-hl", { clear = true }),
	callback = set_highlights,
})

M.default_signs = {
	edit = { text = "M", hl = "PerforceSignEdit" },
	add = { text = "A", hl = "PerforceSignAdd" },
	delete = { text = "D", hl = "PerforceSignDelete" },
	move = { text = "R", hl = "PerforceSignMove" },
	integrate = { text = "I", hl = "PerforceSignIntegrate" },
	dir = { text = "*", hl = "PerforceSignDir" },
}

---p4 action -> sign kind
---@type table<string, string>
M.action_kind = {
	edit = "edit",
	add = "add",
	branch = "add",
	import = "add",
	delete = "delete",
	["move/delete"] = "delete",
	purge = "delete",
	archive = "delete",
	["move/add"] = "move",
	integrate = "integrate",
}

local is_windows = vim.fn.has("win32") == 1

---Normalize a path for comparison (forward slashes, no trailing slash, case-insensitive on Windows)
---@param path string
---@return string
local function norm_key(path)
	local p = vim.fs.normalize(path):gsub("/+$", "")
	if is_windows then
		p = p:lower()
	end
	return p
end

---@class perforce.crude.FsStatus
---@field kind string sign kind
---@field action? string p4 action (files only)
---@field change? string changelist (files only)
---@field count? integer number of opened files below (directories only)

---Build a map of direct-child entry name (normalized, no trailing slash) -> status from `fstat -Ro` records
---@param records { clientFile: string, action?: string, change?: string }[]
---@param dir string directory the crude-fs buffer shows
---@param propagate boolean
---@return table<string, perforce.crude.FsStatus>
function M.build_status(records, dir, propagate)
	local base = norm_key(dir)
	local prefix = base .. "/"
	local status = {}
	for _, rec in ipairs(records) do
		if type(rec.clientFile) == "string" and rec.clientFile ~= "" then
			local path = norm_key(rec.clientFile)
			if path:sub(1, #prefix) == prefix then
				local rel = path:sub(#prefix + 1)
				local first = rel:match("^([^/]+)/.+$")
				if not first then
					status[rel] = {
						kind = M.action_kind[rec.action or ""] or "edit",
						action = rec.action,
						change = rec.change,
					}
				elseif propagate then
					local existing = status[first]
					if existing and existing.kind == "dir" then
						existing.count = existing.count + 1
					elseif not existing then
						status[first] = { kind = "dir", count = 1 }
					end
				end
			end
		end
	end
	return status
end

---@param dir string
---@return string
local function recursive_spec(dir)
	local spec = vim.fs.normalize(dir):gsub("/+$", "") .. "/..."
	if is_windows then
		spec = spec:gsub("/", "\\")
	end
	return spec
end

---@param opts? perforce.crude.FsSignsOptions
---@return crude.Extension
function M.create(opts)
	opts = opts or {}
	local providers = opts.providers or { "crude-fs", "fs" }
	local propagate = opts.propagate_dir_status ~= false
	local refresh_on_focus = opts.refresh_on_focus ~= false
	local priority = opts.priority or 20
	local signs = vim.tbl_deep_extend("force", vim.deepcopy(M.default_signs), opts.signs or {})

	---bufnr -> extension state (same table as ctx.state), for `wait`
	---@type table<integer, table>
	local states = {}

	---@param bufnr integer
	---@return string?
	local function buf_dir(bufnr)
		local dir = vim.b[bufnr].crude_dir
		if not dir or dir == "" then
			local ok, fs = pcall(require, "crude.providers.fs")
			dir = ok and fs.get_dir(bufnr) or nil
		end
		if dir == "" then
			return nil
		end
		return dir
	end

	---@param entry crude.Entry
	---@param state table
	---@return crude.Decoration?
	local function decorate(entry, state)
		if not state.status then
			return nil
		end
		if entry.name == "../" or (entry.meta and entry.meta.is_parent) then
			return nil
		end
		local key = entry.name:gsub("/+$", "")
		if is_windows then
			key = key:lower()
		end
		local st = state.status[key]
		if not st then
			return nil
		end
		local sign = signs[st.kind]
		if not sign or not sign.text or sign.text == "" then
			return nil
		end
		return { sign_text = sign.text, sign_hl_group = sign.hl, priority = priority }
	end

	---Query opened files below the buffer's directory and update decorations
	---@param bufnr integer
	---@param ctx crude.ExtensionContext
	local function refresh(bufnr, ctx)
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local dir = buf_dir(bufnr)
		if not dir then
			return
		end
		local state = ctx.state
		state.token = (state.token or 0) + 1
		state.stale = false
		local token = state.token
		state.pending = true

		local function finish(status)
			if state.token ~= token then
				return -- superseded by a newer refresh
			end
			state.pending = false
			if not vim.api.nvim_buf_is_valid(bufnr) or buf_dir(bufnr) ~= dir then
				return
			end
			state.dir = dir
			state.status = status
			local decs = {}
			for _, entry in ipairs(ctx:get_snapshot()) do
				local dec = decorate(entry, state)
				if dec then
					decs[entry.id] = dec
				end
			end
			ctx:set_decorations(decs)
		end

		perforce.get_workspace_root(dir, function(root)
			if not root then
				finish(nil)
				return
			end
			perforce.fstat({
				files = { recursive_spec(dir) },
				fields = { "clientFile", "action", "change" },
				opened_only = true,
				cwd = dir,
			}, function(_, result)
				local records = {}
				for _, item in ipairs(result or {}) do
					if type(item) == "table" and item.severity == nil and item.clientFile then
						table.insert(records, item)
					end
				end
				finish(M.build_status(records, dir, propagate))
			end)
		end)
	end

	---Refresh now if the buffer is visible, otherwise on next BufEnter
	local function refresh_or_defer(bufnr, ctx)
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		if #vim.fn.win_findbuf(bufnr) > 0 then
			refresh(bufnr, ctx)
		else
			ctx.state.stale = true
		end
	end

	---@type crude.Extension
	local ext = {
		providers = providers,
		patterns = opts.patterns,

		decorate_entry = function(entry, bufnr, ctx)
			local state = ctx.state
			if state.dir and state.dir ~= buf_dir(bufnr) then
				return nil
			end
			return decorate(entry, state)
		end,

		attach = function(bufnr, ctx)
			states[bufnr] = ctx.state
			local group = vim.api.nvim_create_augroup(string.format("perforce-crude-fs-signs-%s-%d", ctx.ext_id, bufnr), { clear = true })
			ctx.state.augroup = group

			vim.api.nvim_create_autocmd("User", {
				group = group,
				pattern = "PerforceOpenedChanged",
				callback = function()
					refresh_or_defer(bufnr, ctx)
				end,
			})
			if refresh_on_focus then
				vim.api.nvim_create_autocmd("FocusGained", {
					group = group,
					callback = function()
						refresh_or_defer(bufnr, ctx)
					end,
				})
			end
			vim.api.nvim_create_autocmd("BufEnter", {
				group = group,
				buffer = bufnr,
				callback = function()
					if ctx.state.stale then
						refresh(bufnr, ctx)
					end
				end,
			})
			vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
				group = group,
				buffer = bufnr,
				callback = function()
					states[bufnr] = nil
					pcall(vim.api.nvim_del_augroup_by_id, group)
				end,
			})

			refresh(bufnr, ctx)
		end,

		detach = function(bufnr, ctx)
			states[bufnr] = nil
			if ctx and ctx.state and ctx.state.augroup then
				pcall(vim.api.nvim_del_augroup_by_id, ctx.state.augroup)
				ctx.state.augroup = nil
			end
		end,
	}

	---Block until the pending query for bufnr finishes (tests / scripting)
	---@param bufnr? integer
	---@param timeout? integer ms (default 2000)
	---@return boolean finished
	function ext.wait(bufnr, timeout)
		bufnr = (bufnr and bufnr > 0) and bufnr or vim.api.nvim_get_current_buf()
		return vim.wait(timeout or 2000, function()
			local st = states[bufnr]
			return st ~= nil and not st.pending
		end, 10)
	end

	---Force a refresh of every attached buffer
	function ext.refresh_all()
		local ok, extension = pcall(require, "crude.extension")
		if not ok then
			return
		end
		for bufnr in pairs(states) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				for _, id in ipairs(extension.get_ids()) do
					local registered = extension.get(id)
					if registered and registered.attach == ext.attach then
						refresh_or_defer(bufnr, extension.get_context(bufnr, id))
					end
				end
			end
		end
	end

	return ext
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
