local perforce = require("perforce")

local M = {}

---Cached client information from p4 info
M.cached_client_info = nil
M.cached_client_timestamp = 0

---Helper to invoke a callback-style perforce function using Neovim's native vim.async.await
---@param argc integer The 1-based index where the callback parameter belongs
---@param fn function The perforce API function
---@param ... any Arguments passed to fn
---@return any errors
---@return any result
local function async_await(argc, fn, ...)
	return vim.async.await(argc, fn, ...)
end

---Parse a p4:// or perforce:// buffer URL into structured info
---@param url string
---@return { type: "overview"|"changelist", mode: string, changelist: string|nil }
function M.parse_url(url)
	assert(type(url) == "string", "url must be a string")
	local path = url:gsub("^perforce://", ""):gsub("^p4://", "")
	path = path:gsub("^/+", "")

	if path == "" or path == "opened" or path == "history" or path == "changes" or path == "pending" then
		local mode = path == "" and "opened" or path
		if mode == "pending" or mode == "changes" then
			mode = "pending"
		end
		return {
			type = "overview",
			mode = mode,
			changelist = nil,
		}
	end

	local cl, subpath = path:match("^([^/]+)/?(.*)$")
	if cl == "opened" or cl == "history" or cl == "changes" or cl == "pending" then
		if subpath and subpath ~= "" then
			return {
				type = "changelist",
				mode = cl,
				changelist = subpath:gsub("/+$", ""),
			}
		else
			return {
				type = "overview",
				mode = cl,
				changelist = nil,
			}
		end
	end

	return {
		type = "changelist",
		mode = "changelist",
		changelist = cl,
	}
end

---Get cached or fresh Perforce client info
---@return table|nil
function M.get_client_info()
	local now = vim.uv.now()
	if M.cached_client_info and (now - M.cached_client_timestamp < 30000) then
		return M.cached_client_info
	end

	local ok, err, info = pcall(function()
		return async_await(1, perforce.info)
	end)

	if ok and info and info.clientName then
		M.cached_client_info = info
		M.cached_client_timestamp = vim.uv.now()
		return info
	end

	return M.cached_client_info
end

---Extract first non-empty line of a changelist description
---@param desc string|nil
---@return string
local function clean_desc(desc)
	if not desc then
		return ""
	end
	for _, line in ipairs(vim.split(desc, "\n")) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			return trimmed
		end
	end
	return ""
end

---Resolve a depot path to a local filesystem path
---@param depot_path string
---@param client_file? string
---@return string|nil
function M.resolve_local_path(depot_path, client_file)
	local client_info = M.get_client_info()

	-- 1. Try mapping clientFile using clientRoot
	if client_file and client_info and client_info.clientRoot and client_info.clientName then
		local prefix = "^//" .. vim.pesc(client_info.clientName) .. "/"
		if client_file:match(prefix) then
			local rel = client_file:gsub(prefix, ""):gsub("\\", "/")
			local local_path = vim.fs.normalize(vim.fs.joinpath(client_info.clientRoot, rel))
			if vim.fn.filereadable(local_path) == 1 then
				return local_path
			end
		end
	end

	-- 2. Try p4 where
	local ok, err, where_res = pcall(function()
		return async_await(2, perforce.where, { depot_path })
	end)
	if ok and where_res and where_res[1] and where_res[1].path then
		local norm_path = vim.fs.normalize(where_res[1].path)
		return norm_path
	end

	return nil
end

---Crude Provider Columns
M.columns = {
	{
		name = "action",
		editable = false,
		render = function(entry, bufnr)
			local act = entry.columns and entry.columns.action or ""
			local hl = "Normal"
			if act == "edit" then
				hl = "DiffChange"
			elseif act == "add" or act == "branch" then
				hl = "DiffAdd"
			elseif act == "delete" then
				hl = "DiffDelete"
			elseif act == "integrate" then
				hl = "Special"
			elseif act == "*pending*" then
				hl = "DiagnosticWarn"
			elseif act == "submitted" then
				hl = "Comment"
			end
			return act, hl
		end,
	},
}

---List entries in a buffer for Crude
---@param bufnr integer
---@return crude.Entry[]
function M.list(bufnr)
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local info = M.parse_url(bufname)
	local client_info = M.get_client_info()

	if info.type == "overview" then
		local entries = {}

		if info.mode == "history" then
			-- History view: list latest changelists server-wide
			local err, changes = async_await(2, perforce.changes, {
				max = 50,
				full_description = true,
			})
			if err then
				error(type(err) == "table" and table.concat(err, "\n") or tostring(err))
			end

			for _, ch in ipairs(changes or {}) do
				local cl = tostring(ch.change)
				table.insert(entries, {
					id = "cl:" .. cl,
					name = cl .. "/",
					columns = {
						action = ch.status == "pending" and "*pending*" or "submitted",
					},
					meta = {
						type = "changelist_dir",
						changelist = cl,
						user = ch.user or "unknown",
						desc = clean_desc(ch.desc),
						status = ch.status,
					},
				})
			end
		elseif info.mode == "opened" then
			-- Opened view: list only changelists that have opened files
			local err, opened_list = async_await(2, perforce.opened, {})
			if err then
				error(type(err) == "table" and table.concat(err, "\n") or tostring(err))
			end

			local cl_counts = {}
			local cl_order = {}
			for _, item in ipairs(opened_list or {}) do
				local cl = item.change or "default"
				if not cl_counts[cl] then
					table.insert(cl_order, cl)
					cl_counts[cl] = 0
				end
				cl_counts[cl] = cl_counts[cl] + 1
			end

			-- Look up descriptions for pending changelists
			local desc_map = { default = "Default changelist" }
			if client_info and client_info.userName and client_info.clientName then
				local _, changes = async_await(2, perforce.changes, {
					status = "pending",
					user = client_info.userName,
					client = client_info.clientName,
					full_description = true,
				})
				for _, ch in ipairs(changes or {}) do
					desc_map[tostring(ch.change)] = clean_desc(ch.desc)
				end
			end

			for _, cl in ipairs(cl_order) do
				table.insert(entries, {
					id = "cl:" .. cl,
					name = cl .. "/",
					columns = {
						action = "",
					},
					meta = {
						type = "changelist_dir",
						changelist = cl,
						count = cl_counts[cl],
						desc = desc_map[cl] or "",
						user = client_info and client_info.userName or "",
					},
				})
			end
		else
			-- Pending view: list all pending changelists for user
			local desc_map = { default = "Default changelist" }
			local changes = {}
			if client_info and client_info.userName and client_info.clientName then
				local _, ch_list = async_await(2, perforce.changes, {
					status = "pending",
					user = client_info.userName,
					client = client_info.clientName,
					full_description = true,
				})
				changes = ch_list or {}
				for _, ch in ipairs(changes) do
					desc_map[tostring(ch.change)] = clean_desc(ch.desc)
				end
			end

			table.insert(entries, {
				id = "cl:default",
				name = "default/",
				columns = { action = "" },
				meta = {
					type = "changelist_dir",
					changelist = "default",
					desc = "Default changelist",
					user = client_info and client_info.userName or "",
				},
			})

			for _, ch in ipairs(changes) do
				local cl = tostring(ch.change)
				table.insert(entries, {
					id = "cl:" .. cl,
					name = cl .. "/",
					columns = { action = "" },
					meta = {
						type = "changelist_dir",
						changelist = cl,
						desc = clean_desc(ch.desc),
						user = ch.user or (client_info and client_info.userName) or "",
					},
				})
			end
		end

		return entries
	else
		-- Changelist view: Flat list of all opened files in this changelist with full depot paths!
		local cl = info.changelist
		local entries = {}

		local err, opened_list = async_await(2, perforce.opened, { changelist = cl })

		if opened_list and #opened_list > 0 then
			for _, item in ipairs(opened_list) do
				assert(item.depotFile and item.depotFile ~= "", "Perforce item must have depotFile")
				table.insert(entries, {
					id = item.depotFile,
					name = item.depotFile, -- PROPER DEPOT PATH (e.g. //depot/my_project/src/file.cpp)
					columns = {
						action = item.action or "edit",
					},
					meta = {
						type = "file",
						depotFile = item.depotFile,
						clientFile = item.clientFile,
						action = item.action,
						changelist = cl,
						rev = item.rev,
						filetype = item.type,
						user = item.user,
					},
				})
			end
		else
			-- Fallback to describe for submitted or historical changelists
			local desc_err, desc_info = async_await(2, perforce.describe, cl)
			if desc_info and desc_info.files and #desc_info.files > 0 then
				for _, item in ipairs(desc_info.files) do
					table.insert(entries, {
						id = item.depotFile,
						name = item.depotFile, -- PROPER DEPOT PATH
						columns = {
							action = item.action or "edit",
						},
						meta = {
							type = "file",
							depotFile = item.depotFile,
							action = item.action,
							changelist = cl,
							rev = item.rev,
							filetype = item.type,
							readonly = (desc_info.status == "submitted"),
						},
					})
				end
			elseif err then
				error(type(err) == "table" and table.concat(err, "\n") or tostring(err))
			end
		end

		return entries
	end
end

---Custom formatting for changelist overview entries
---@param entry crude.Entry
---@param bufnr integer
---@return string|table, table[]?
function M.render_entry(entry, bufnr)
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local info = M.parse_url(bufname)

	if info.type == "overview" and entry.meta and entry.meta.type == "changelist_dir" then
		local parts = {
			{ entry.name, "Directory" },
		}

		if entry.meta.count then
			local count_str = string.format(" [%d file%s]", entry.meta.count, entry.meta.count == 1 and "" or "s")
			table.insert(parts, { count_str, "Comment" })
		end

		if entry.meta.user and entry.meta.user ~= "" then
			table.insert(parts, { " (" .. entry.meta.user .. ")", "Identifier" })
		end

		if entry.meta.desc and entry.meta.desc ~= "" then
			table.insert(parts, { "  " .. entry.meta.desc, "Normal" })
		end

		return parts
	end

	return entry.name
end

---Validate entry names in Crude buffers
---@param name string
---@param bufnr integer
---@return boolean, string?
function M.validate_entry_name(name, bufnr)
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local info = M.parse_url(bufname)

	if info.type == "changelist" then
		-- In changelist buffers, entry names should be valid depot paths or local file paths
		if not name:match("^//") and not name:match("^%a:[/\\]") and not name:match("^/") and not name:match("^%.[/\\]") then
			return false, "Entry must be a valid Perforce depot path (e.g. //depot/path/file.cpp) or file path"
		end
		return true
	end

	return true
end

---Apply diffs to Perforce backend
---@param bufnr integer
---@param diffs crude.DiffResult
function M.apply(bufnr, diffs)
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local info = M.parse_url(bufname)

	if info.type == "overview" then
		error("Overview buffers are read-only. Edit entries within specific changelist buffers.")
	end

	local target_cl = info.changelist
	assert(target_cl and target_cl ~= "", "Cannot save without a valid changelist")

	-- 1. Apply renames (p4 move)
	for _, ren in ipairs(diffs.renames) do
		local err, res = async_await(2, perforce.move, {
			changelist = target_cl,
			from_file = ren.from,
			to_file = ren.to,
		})
		if err then
			error(type(err) == "table" and table.concat(err, "\n") or tostring(err))
		end
	end

	-- Helper to check if a deleted entry was moved into another crude buffer
	local function is_entry_moved_elsewhere(id)
		if not id then
			return false
		end
		local id_pat = "^@@" .. vim.pesc(tostring(id)) .. "%s"
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "crude" and b ~= bufnr then
				local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
				for _, line in ipairs(lines) do
					if line:match(id_pat) then
						return true
					end
				end
			end
		end
		return false
	end

	-- 2. Apply creates:
	--    - If src_id exists -> cross-buffer reopen from another changelist!
	--    - If freshly typed path -> p4 edit or p4 add into this changelist!
	local reopen_files = {}
	local new_files = {}
	for _, cr in ipairs(diffs.creates) do
		if cr.src_id then
			table.insert(reopen_files, cr.name)
		else
			table.insert(new_files, cr.name)
		end
	end

	if #reopen_files > 0 then
		local err, res = async_await(2, perforce.reopen, {
			changelist = target_cl,
			files = reopen_files,
		})
		if err then
			error(type(err) == "table" and table.concat(err, "\n") or tostring(err))
		end
	end

	for _, name in ipairs(new_files) do
		local err, res = async_await(2, perforce.edit, {
			changelist = target_cl,
			files = { name },
		})
		if err then
			local add_err, add_res = async_await(2, perforce.add, {
				changelist = target_cl,
				files = { name },
			})
			if add_err then
				error(string.format("Failed to edit or add '%s': %s", name, table.concat(add_err, "\n")))
			end
		end
	end

	-- 3. Apply deletes (p4 revert)
	local revert_files = {}
	for _, del in ipairs(diffs.deletes) do
		if not is_entry_moved_elsewhere(del.id) then
			table.insert(revert_files, del.name)
		end
	end

	if #revert_files > 0 then
		local err, res = async_await(2, perforce.revert, {
			changelist = target_cl,
			files = revert_files,
		})
		if err then
			error(type(err) == "table" and table.concat(err, "\n") or tostring(err))
		end
	end
end

---Selecting an entry (<CR>) in a Crude buffer
---@param entry crude.Entry
---@param bufnr integer
function M.on_select(entry, bufnr)
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local info = M.parse_url(bufname)

	if info.type == "overview" then
		-- Navigate into the selected changelist
		local cl = entry.name:gsub("/+$", "")
		local target = "p4://" .. cl
		vim.cmd("edit " .. vim.fn.fnameescape(target))
	else
		-- In a changelist buffer: open the local workspace file for the depot path!
		local depot_path = entry.name
		local client_file = entry.meta and entry.meta.clientFile
		local local_path = M.resolve_local_path(depot_path, client_file)

		if local_path and vim.fn.filereadable(local_path) == 1 then
			vim.cmd("edit " .. vim.fn.fnameescape(local_path))
			return
		end

		-- If not on local disk, print depot file into a scratch view buffer
		local err, content = async_await(2, perforce.print, { file = depot_path })
		if content then
			local print_buf = vim.api.nvim_create_buf(false, true)
			local lines = vim.split(content, "\n", { plain = true })
			vim.api.nvim_buf_set_lines(print_buf, 0, -1, false, lines)
			vim.bo[print_buf].buftype = "nofile"
			vim.bo[print_buf].bufhidden = "hide"
			vim.bo[print_buf].readonly = true

			local fname = vim.fs.basename(depot_path)
			pcall(vim.api.nvim_buf_set_name, print_buf, "p4://" .. depot_path:gsub("^//", ""))
			local ft = vim.filetype.match({ buf = print_buf, filename = fname })
			if ft then
				vim.bo[print_buf].filetype = ft
			end

			vim.api.nvim_set_current_buf(print_buf)
		else
			if local_path then
				vim.cmd("edit " .. vim.fn.fnameescape(local_path))
			else
				vim.notify(string.format("[perforce] File not available locally: %s", depot_path), vim.log.levels.WARN)
			end
		end
	end
end

---Navigate to parent (-) in a Crude buffer
---@param bufnr integer
function M.on_parent(bufnr)
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local info = M.parse_url(bufname)

	if info.type == "changelist" then
		-- From changelist buffer, go up to overview
		if info.mode == "history" then
			vim.cmd("edit p4://history")
		else
			vim.cmd("edit p4://opened")
		end
	elseif info.type == "overview" and (info.mode == "history" or info.mode == "pending") then
		vim.cmd("edit p4://opened")
	else
		vim.notify("[perforce] Already at root changelist overview", vim.log.levels.INFO)
	end
end

return M
