local cache = require("oil.cache")
local fs = require("oil.fs")
local pathutil = require("oil.pathutil")
local perforce = require("perforce")
local util = require("oil.util")

local M = {}

M.name = "p4"
M.supported_cross_adapter_actions = { files = "move" }

---Cached client information from p4 info
M.cached_client_info = nil
M.cached_client_timestamp = 0

---Map of changelist string -> description string
M.changelist_descriptions = {}

---Map of changelist string -> author / user string
M.changelist_authors = {}

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

---List of pending changelists (including "opened", "history", "default") for completion
M.pending_changelists = { "opened", "history", "default" }

---Map of changelist string -> array of opened file entries from p4 opened
M.opened_by_cl = {}

---Map of buffer url -> (map of entry_name -> action)
M.status_map_by_url = {}

---Map of buffer url -> (map of entry_name -> directory path string)
M.dir_map_by_url = {}

---Map of "<changelist>:<entry_name>" -> relative path from workspace root
M.file_relpath_by_cl_and_name = {}

---Map of "<changelist>:<entry_name>" -> Perforce clientFile (//client/...)
M.file_clientfile_by_cl_and_name = {}

---Map of changelist string -> true for submitted/read-only changelists
M.readonly_changelists = {}

---Get cached or fresh Perforce client info
---@param callback fun(info: table|nil)
function M.get_client_info(callback)
	local now = vim.uv.now()
	if M.cached_client_info and (now - M.cached_client_timestamp < 30000) then
		callback(M.cached_client_info)
		return
	end

	perforce.info(function(err, info)
		if info and info.clientName then
			M.cached_client_info = info
			M.cached_client_timestamp = vim.uv.now()
			callback(info)
		else
			callback(nil)
		end
	end)
end

---@class P4ParsedUrl
---@field scheme string
---@field changelist string|nil
---@field subpath string|nil

---Parse an oil-p4:// or p4:// URL into changelist and subpath components
---@param url string
---@return P4ParsedUrl
function M.parse_url(url)
	local scheme, path = util.parse_url(url)
	if not scheme then
		if url:match("^p4://") then
			scheme = "p4://"
			path = url:sub(6)
		else
			scheme = "oil-p4://"
			path = url:gsub("^oil%-p4://", "")
		end
	end

	path = path or ""
	path = path:gsub("^/+", "")

	if path == "" then
		return {
			scheme = scheme,
			changelist = nil,
			subpath = nil,
		}
	end

	local changelist, subpath = path:match("^([^/]+)/?(.*)$")
	if subpath == "" then
		subpath = nil
	end

	return {
		scheme = scheme,
		changelist = changelist,
		subpath = subpath,
	}
end

---Normalize a URL before Oil opens it
---@param url string
---@param callback fun(url: string)
function M.normalize_url(url, callback)
	local parsed = M.parse_url(url)
	if not parsed.changelist then
		callback("oil-p4://")
		return
	end

	if parsed.changelist == "opened" then
		callback("oil-p4://opened/")
		return
	end

	if parsed.changelist == "history" then
		callback("oil-p4://history/")
		return
	end

	if not parsed.subpath then
		callback("oil-p4://" .. parsed.changelist .. "/")
		return
	end

	-- Subpath is a file in a changelist buffer
	local cl = parsed.changelist
	local entry_name = parsed.subpath:gsub("/+$", "")
	local relpath = M.file_relpath_by_cl_and_name[cl .. ":" .. entry_name]
	local depot_path = M.file_clientfile_by_cl_and_name[cl .. ":" .. entry_name]

	M.get_client_info(function(client_info)
		if client_info and client_info.clientRoot and relpath then
			local full_path = vim.fs.joinpath(client_info.clientRoot, relpath)
			callback(vim.fs.normalize(full_path))
		elseif depot_path and depot_path:match("^//") then
			perforce.where({ depot_path }, function(where_err, where_res)
				if where_res and where_res[1] and where_res[1].path then
					callback(vim.fs.normalize(where_res[1].path))
				else
					callback("oil-p4://" .. parsed.changelist .. "/" .. parsed.subpath)
				end
			end)
		elseif client_info and client_info.clientRoot and parsed.subpath then
			local full_path = vim.fs.joinpath(client_info.clientRoot, parsed.subpath)
			callback(vim.fs.normalize(full_path))
		else
			callback("oil-p4://" .. parsed.changelist .. "/" .. parsed.subpath)
		end
	end)
end

---Map of changelist buffer URL -> parent overview URL (e.g. oil-p4://opened/)
M.parent_overview_by_url = {}

---Return the parent URL for hierarchical navigation ("-")
---@param bufname string
---@return string
function M.get_parent(bufname)
	local parsed = M.parse_url(bufname)
	if not parsed.changelist then
		-- In root overview (oil-p4://): go up to filesystem Oil buffer
		local client_info = M.cached_client_info
		local target_dir = (client_info and client_info.clientRoot) or vim.fn.getcwd()
		local root_posix = fs.os_to_posix_path(vim.fs.normalize(target_dir))
		return "oil://" .. util.addslash(root_posix)
	elseif parsed.changelist == "opened" or parsed.changelist == "history" then
		-- In opened or history overview: go up to root changelist overview
		pcall(function()
			local view = require("oil.view")
			view.set_last_cursor("oil-p4://", parsed.changelist .. "/")
		end)
		return "oil-p4://"
	end

	-- From a changelist buffer (oil-p4://<cl>/)
	local parent = M.parent_overview_by_url[bufname]
	if not parent then
		local norm_url = "oil-p4://" .. parsed.changelist .. "/"
		parent = M.parent_overview_by_url[norm_url]
	end
	parent = parent or "oil-p4://"

	pcall(function()
		local view = require("oil.view")
		view.set_last_cursor(parent, parsed.changelist .. "/")
	end)

	return parent
end

---Called when selecting an entry (<CR>) in an Oil buffer
---@param url string
---@param entry oil.Entry
---@param callback fun(path: string)
function M.get_entry_path(url, entry, callback)
	local parsed = M.parse_url(url)
	if (parsed.changelist == "opened" or parsed.changelist == "history") and entry.type == "directory" then
		local target_url = "oil-p4://" .. entry.name .. "/"
		M.parent_overview_by_url[target_url] = "oil-p4://" .. parsed.changelist .. "/"
		callback(target_url)
		return
	end

	if not parsed.changelist and entry.type == "directory" then
		local target_url = "oil-p4://" .. entry.name .. "/"
		M.parent_overview_by_url[target_url] = "oil-p4://"
		callback(target_url)
		return
	end

	if entry.type == "directory" then
		callback(util.addslash(url))
		return
	end

	-- It is a file entry in a changelist buffer
	local cl = parsed.changelist
	local entry_name = entry.name
	local relpath = M.file_relpath_by_cl_and_name[cl .. ":" .. entry_name]
	local depot_path = M.file_clientfile_by_cl_and_name[cl .. ":" .. entry_name]

	M.get_client_info(function(client_info)
		if client_info and client_info.clientRoot and relpath then
			local full_os_path = vim.fs.joinpath(client_info.clientRoot, relpath)
			callback(vim.fs.normalize(full_os_path))
		elseif depot_path and depot_path:match("^//") then
			perforce.where({ depot_path }, function(where_err, where_res)
				if where_res and where_res[1] and where_res[1].path then
					callback(vim.fs.normalize(where_res[1].path))
				else
					callback(depot_path)
				end
			end)
		elseif client_info and client_info.clientRoot and parsed.subpath then
			local full_os_path = vim.fs.joinpath(client_info.clientRoot, parsed.subpath)
			callback(vim.fs.normalize(full_os_path))
		else
			callback(relpath or entry_name)
		end
	end)
end

---Return custom column definition if requested
---@param name string
---@return nil|oil.ColumnDefinition
function M.get_column(name)
	if name == "author" or name == "user" or name == "p4_user" then
		return {
			render = function(entry, conf)
				local cl = entry[2] or entry.name
				local author = M.changelist_authors[cl]
				if not author and entry[4] then
					author = entry[4].author
				end
				if not author or author == "" then
					return { "-", "OilEmpty" }
				end
				local hl = (conf and conf.highlight) or "OilP4Author"
				if type(hl) == "function" then
					hl = hl(author)
				end
				return { author, hl }
			end,
			parse = function(line, conf)
				return line:match("^(%S+)%s+(.*)$")
			end,
			compare = function(entry, parsed_value)
				local cl = entry[2] or entry.name
				local old_author = M.changelist_authors[cl] or (entry[4] and entry[4].author)
				return old_author ~= parsed_value
			end,
			get_sort_value = function(entry)
				local cl = entry[2] or entry.name
				return M.changelist_authors[cl] or ""
			end,
		}
	elseif name == "p4_desc" then
		return {
			render = function(entry)
				local desc = M.changelist_descriptions[entry.name]
				if desc and desc ~= "" then
					local first_line = vim.split(desc, "\n")[1]
					return first_line
				end
				return ""
			end,
			parse = function()
				return nil
			end,
		}
	elseif name == "p4_dir" then
		return {
			render = function(entry)
				local bufname = vim.api.nvim_buf_get_name(0)
				local dir_map = M.dir_map_by_url[bufname]
				if dir_map and dir_map[entry.name] then
					return dir_map[entry.name]
				end
				return ""
			end,
			parse = function()
				return nil
			end,
		}
	end
	return nil
end

---Build entries, status_map, and dir_map from p4 opened list
---@param opened_list table[]
---@param cl string
---@param url? string
---@return oil.InternalEntry[] entries, table<string, string> status_map, table<string, string> dir_map
function M.build_maps_from_opened(opened_list, cl, url)
	local name_counts = {}
	for _, item in ipairs(opened_list) do
		local rel = item.clientFile:gsub("^//[^/]+/", ""):gsub("\\", "/")
		local fname = vim.fs.basename(rel)
		name_counts[fname] = (name_counts[fname] or 0) + 1
	end

	local entries = {}
	local status_map = {}
	local dir_map = {}

	for _, item in ipairs(opened_list) do
		local rel = item.clientFile:gsub("^//[^/]+/", ""):gsub("\\", "/")
		local fname = vim.fs.basename(rel)
		local dname = vim.fs.dirname(rel)
		if dname == "." then
			dname = ""
		end

		local entry_name = fname
		if name_counts[fname] > 1 then
			local parent_folder = vim.fs.basename(dname)
			if parent_folder and parent_folder ~= "" then
				entry_name = string.format("%s (%s)", fname, parent_folder)
			else
				entry_name = string.format("%s (%s)", fname, dname)
			end
		end

		if url then
			local entry = cache.create_entry(url, entry_name, "file")
			table.insert(entries, entry)
		end

		status_map[entry_name] = item.action or "edit"
		dir_map[entry_name] = dname ~= "" and (dname .. "/") or ""
		M.file_relpath_by_cl_and_name[cl .. ":" .. entry_name] = rel
		M.file_clientfile_by_cl_and_name[cl .. ":" .. entry_name] = item.clientFile
	end

	return entries, status_map, dir_map
end

---Build entries, status_map, and dir_map from p4 describe files list
---@param desc_files table[]
---@param cl string
---@param url? string
---@return oil.InternalEntry[] entries, table<string, string> status_map, table<string, string> dir_map
function M.build_maps_from_describe(desc_files, cl, url)
	local name_counts = {}
	for _, item in ipairs(desc_files) do
		local fname = vim.fs.basename(item.depotFile)
		name_counts[fname] = (name_counts[fname] or 0) + 1
	end

	local entries = {}
	local status_map = {}
	local dir_map = {}

	for _, item in ipairs(desc_files) do
		local fname = vim.fs.basename(item.depotFile)
		local dname = vim.fs.dirname(item.depotFile)
		if dname == "." then
			dname = ""
		end

		local entry_name = fname
		if name_counts[fname] > 1 then
			local parent_folder = vim.fs.basename(dname)
			if parent_folder and parent_folder ~= "" then
				entry_name = string.format("%s (%s)", fname, parent_folder)
			else
				entry_name = string.format("%s (%s)", fname, dname)
			end
		end

		if url then
			local entry = cache.create_entry(url, entry_name, "file")
			table.insert(entries, entry)
		end

		status_map[entry_name] = item.action or "edit"
		dir_map[entry_name] = dname ~= "" and (dname .. "/") or ""
		M.file_clientfile_by_cl_and_name[cl .. ":" .. entry_name] = item.depotFile
	end

	return entries, status_map, dir_map
end

---List entries in a directory buffer
---@param url string
---@param column_defs string[]
---@param callback fun(err?: string, entries?: oil.InternalEntry[], fetch_more?: fun())
function M.list(url, column_defs, callback)
	local parsed = M.parse_url(url)

	if not parsed.changelist then
		-- Root view: list pending changelists for current user
		M.get_client_info(function(client_info)
			if not client_info then
				callback("Could not determine Perforce client info (p4 info failed)")
				return
			end

			-- Query opened files to show file counts on active changelists
			perforce.opened({}, function(_, opened_list)
				local cl_counts = {}
				for _, item in ipairs(opened_list or {}) do
					local cl = item.change or "default"
					cl_counts[cl] = (cl_counts[cl] or 0) + 1
				end

				perforce.changes({
					status = "pending",
					user = client_info.userName,
					client = client_info.clientName,
					full_description = true,
				}, function(err, changes_list)
					if err then
						callback(table.concat(err, "\n"))
						return
					end

					local entries = {}
					M.changelist_descriptions = {}
					M.pending_changelists = { "opened", "history", "default" }

					-- Always include the "default" changelist
					local default_entry = cache.create_entry(url, "default", "directory")
					table.insert(entries, default_entry)
					M.changelist_authors["default"] = client_info.userName
					if cl_counts["default"] then
						M.changelist_descriptions["default"] = string.format(
							"[%d file%s]  Default changelist",
							cl_counts["default"],
							cl_counts["default"] == 1 and "" or "s"
						)
					else
						M.changelist_descriptions["default"] = "Default changelist"
					end

					if changes_list then
						for _, ch in ipairs(changes_list) do
							local cl_name = tostring(ch.change)
							local entry = cache.create_entry(url, cl_name, "directory")
							table.insert(entries, entry)
							M.changelist_authors[cl_name] = ch.user or client_info.userName
							local desc = clean_desc(ch.desc)
							if cl_counts[cl_name] then
								if desc ~= "" then
									M.changelist_descriptions[cl_name] = string.format(
										"[%d file%s]  %s",
										cl_counts[cl_name],
										cl_counts[cl_name] == 1 and "" or "s",
										desc
									)
								else
									M.changelist_descriptions[cl_name] = string.format(
										"[%d file%s]",
										cl_counts[cl_name],
										cl_counts[cl_name] == 1 and "" or "s"
									)
								end
							else
								M.changelist_descriptions[cl_name] = desc
							end
							table.insert(M.pending_changelists, cl_name)
						end
					end

					callback(nil, entries)
				end)
			end)
		end)
	elseif parsed.changelist == "opened" then
		-- Opened view: list only changelists that currently have opened files
		M.get_client_info(function(client_info)
			if not client_info then
				callback("Could not determine Perforce client info (p4 info failed)")
				return
			end

			perforce.opened({}, function(opened_err, opened_list)
				if opened_err then
					callback(table.concat(opened_err, "\n"))
					return
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

				perforce.changes({
					status = "pending",
					user = client_info.userName,
					client = client_info.clientName,
					full_description = true,
				}, function(_, changes_list)
					local desc_map = { default = "Default changelist" }
					if changes_list then
						for _, ch in ipairs(changes_list) do
							desc_map[tostring(ch.change)] = clean_desc(ch.desc)
						end
					end

					local entries = {}
					M.changelist_descriptions = {}

					for _, cl in ipairs(cl_order) do
						local entry = cache.create_entry(url, cl, "directory")
						table.insert(entries, entry)
						M.changelist_authors[cl] = client_info.userName
						local count = cl_counts[cl]
						local desc = desc_map[cl] or ""
						local count_str = string.format("[%d file%s]", count, count == 1 and "" or "s")
						if desc ~= "" then
							M.changelist_descriptions[cl] = count_str .. "  " .. desc
						else
							M.changelist_descriptions[cl] = count_str
						end
					end

					callback(nil, entries)
				end)
			end)
		end)
	elseif parsed.changelist == "history" then
		-- History view: list latest changelists from everyone across the server
		perforce.changes({
			max = 50,
			full_description = true,
		}, function(err, changes_list)
			if err then
				callback(table.concat(err, "\n"))
				return
			end

			local entries = {}
			M.changelist_descriptions = {}

			if changes_list then
				for _, ch in ipairs(changes_list) do
					local cl_name = tostring(ch.change)
					local entry = cache.create_entry(url, cl_name, "directory")
					table.insert(entries, entry)
					local desc = clean_desc(ch.desc)
					local user_str = ch.user or "unknown"
					M.changelist_authors[cl_name] = user_str
					local status_tag = ch.status == "pending" and "*pending*" or ""
					if desc ~= "" then
						if status_tag ~= "" then
							M.changelist_descriptions[cl_name] = status_tag .. "  " .. desc
						else
							M.changelist_descriptions[cl_name] = desc
						end
					else
						M.changelist_descriptions[cl_name] = status_tag
					end
				end
			end

			callback(nil, entries)
		end)
	else
		-- Changelist view: Flat list of all opened files in this changelist (or describe for submitted)
		local cl = parsed.changelist

		perforce.opened({ changelist = cl }, function(err, opened_list)
			if err or not opened_list or #opened_list == 0 then
				-- Fallback to p4 describe for submitted or non-opened changelists
				perforce.describe(cl, function(desc_err, desc_info)
					if desc_err or not desc_info or not desc_info.files or #desc_info.files == 0 then
						if err then
							callback(table.concat(err, "\n"))
						else
							callback(nil, {})
						end
						return
					end

					if desc_info.status == "submitted" then
						M.readonly_changelists[cl] = true
					end

					local entries, status_map, dir_map = M.build_maps_from_describe(desc_info.files, cl, url)
					local norm = url:gsub("/+$", "")
					M.status_map_by_url[norm] = status_map
					M.status_map_by_url[norm .. "/"] = status_map
					M.dir_map_by_url[norm] = dir_map
					M.dir_map_by_url[norm .. "/"] = dir_map
					callback(nil, entries)
				end)
				return
			end

			opened_list = opened_list or {}
			M.opened_by_cl[cl] = opened_list

			local entries, status_map, dir_map = M.build_maps_from_opened(opened_list, cl, url)
			local norm = url:gsub("/+$", "")
			M.status_map_by_url[norm] = status_map
			M.status_map_by_url[norm .. "/"] = status_map
			M.dir_map_by_url[norm] = dir_map
			M.dir_map_by_url[norm .. "/"] = dir_map
			callback(nil, entries)
		end)
	end
end

---Root, opened, and history overview buffers and submitted changelists are read-only
---@param bufnr integer
---@return boolean
function M.is_modifiable(bufnr)
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local parsed = M.parse_url(bufname)
	if not parsed.changelist or parsed.changelist == "opened" or parsed.changelist == "history" then
		return false
	end
	if M.readonly_changelists[parsed.changelist] then
		return false
	end
	return true
end

---Render mutation preview line for confirmation modal
---@param action oil.Action
---@return string
function M.render_action(action)
	if action.type == "move" then
		local src_parsed = M.parse_url(action.src_url)
		local dest_parsed = M.parse_url(action.dest_url)

		local target_cl = dest_parsed.changelist
		if target_cl == "opened" and dest_parsed.subpath then
			target_cl = dest_parsed.subpath:match("^([^/]+)")
		end

		if src_parsed.changelist and target_cl then
			if src_parsed.changelist == target_cl then
				error("Renaming files within the same changelist is not supported. Only moving between changelists is supported.")
			end
			local filename = vim.fs.basename(src_parsed.subpath or action.src_url)
			return string.format("  REOPEN %s (CL %s -> CL %s)", filename, src_parsed.changelist, target_cl)
		elseif target_cl then
			local filename = vim.fs.basename(action.src_url)
			return string.format("  REOPEN %s -> CL %s", filename, target_cl)
		else
			return string.format("  MOVE %s -> %s", action.src_url, action.dest_url)
		end
	elseif action.type == "delete" then
		error("Deleting files from oil-p4 buffers is disabled to prevent accidental reverts.")
	elseif action.type == "create" then
		error("Creating files in oil-p4 buffers is disabled.")
	else
		error(string.format("Action %s not supported in oil-p4", action.type))
	end
end

---Execute the mutation action
---@param action oil.Action
---@param callback fun(err?: string)
function M.perform_action(action, callback)
	if action.type ~= "move" then
		callback(string.format("Action %s is not supported in oil-p4", action.type))
		return
	end

	local dest_parsed = M.parse_url(action.dest_url)
	local target_cl = dest_parsed.changelist
	if target_cl == "opened" and dest_parsed.subpath then
		target_cl = dest_parsed.subpath:match("^([^/]+)")
	end

	if not target_cl or target_cl == "opened" then
		callback("Cannot reopen file: destination is not a changelist: " .. action.dest_url)
		return
	end

	local src_parsed = M.parse_url(action.src_url)

	M.get_client_info(function(client_info)
		if src_parsed.changelist then
			local src_cl = src_parsed.changelist
			if src_cl == target_cl then
				callback("File is already in changelist " .. target_cl)
				return
			end

			local entry_name = src_parsed.subpath or ""

			local function do_reopen(client_file)
				perforce.reopen({
					changelist = target_cl,
					files = { client_file },
				}, function(err, result)
					M.opened_by_cl[src_cl] = nil
					M.opened_by_cl[target_cl] = nil
					M.status_map_by_url = {}
					M.dir_map_by_url = {}
					M.file_relpath_by_cl_and_name = {}
					M.file_clientfile_by_cl_and_name = {}

					if err then
						callback(table.concat(err, "\n"))
					elseif result and result[1] and result[1].severity and tonumber(result[1].severity) >= 2 then
						callback(result[1].data or ("Failed to reopen file in changelist " .. target_cl))
					else
						callback(nil)
					end
				end)
			end

			local function find_in_opened(opened, name)
				for _, item in ipairs(opened or {}) do
					local rel = item.clientFile:gsub("^//[^/]+/", ""):gsub("\\", "/")
					local fname = vim.fs.basename(rel)
					if fname == name or rel == name or name:find("^" .. vim.pesc(fname) .. " %(") then
						return item.clientFile
					end
				end
				return nil
			end

			local found = find_in_opened(M.opened_by_cl[src_cl], entry_name)
			if found then
				do_reopen(found)
			else
				perforce.opened({ changelist = src_cl }, function(_, fresh_opened)
					found = find_in_opened(fresh_opened, entry_name)
					if found then
						do_reopen(found)
					else
						callback("No opened file found in changelist " .. src_cl .. " matching " .. action.src_url)
					end
				end)
			end
		else
			-- Cross-adapter move from files adapter (oil://)
			local _, src_path = util.parse_url(action.src_url)
			if not src_path then
				callback("Invalid source URL: " .. action.src_url)
				return
			end
			local local_file = fs.posix_to_os_path(src_path)

			perforce.reopen({
				changelist = target_cl,
				files = { local_file },
			}, function(err, _)
				if not err then
					M.opened_by_cl[target_cl] = nil
					M.status_map_by_url = {}
					M.dir_map_by_url = {}
					callback(nil)
				else
					perforce.edit({
						changelist = target_cl,
						files = { local_file },
					}, function(edit_err, _)
						if not edit_err then
							M.opened_by_cl[target_cl] = nil
							M.status_map_by_url = {}
							M.dir_map_by_url = {}
							callback(nil)
						else
							perforce.add({
								changelist = target_cl,
								files = { local_file },
							}, function(add_err, _)
								if add_err then
									callback(table.concat(add_err, "\n"))
								else
									M.opened_by_cl[target_cl] = nil
									M.status_map_by_url = {}
									M.dir_map_by_url = {}
									callback(nil)
								end
							end)
						end
					end)
				end
			end)
		end
	end)
end

---Register the p4 adapter in oil.nvim
function M.setup()
	local ok, oil_config = pcall(require, "oil.config")
	if not ok then
		return
	end

	local function register()
		if not oil_config.adapters then
			oil_config.adapters = {}
		end
		if not oil_config.adapter_aliases then
			oil_config.adapter_aliases = {}
		end
		if not oil_config.adapter_to_scheme then
			oil_config.adapter_to_scheme = {}
		end
		if not oil_config._adapter_by_scheme then
			oil_config._adapter_by_scheme = {}
		end

		oil_config.adapters["oil-p4://"] = "p4"
		oil_config.adapters["p4://"] = "p4"
		oil_config.adapter_aliases["p4://"] = "oil-p4://"
		oil_config.adapter_to_scheme["p4"] = "oil-p4://"
		oil_config._adapter_by_scheme["oil-p4://"] = M
		oil_config._adapter_by_scheme["p4://"] = M

		local ok_col, columns = pcall(require, "oil.columns")
		if ok_col then
			vim.api.nvim_set_hl(0, "OilP4Author", { link = "Identifier", default = true })

			local author_col = M.get_column("author")
			if author_col then
				columns.register("author", author_col)
				columns.register("user", author_col)
				columns.register("p4_user", author_col)
			end

			if not columns._p4_wrapped then
				columns._p4_wrapped = true
				local orig_get_supported_columns = columns.get_supported_columns
				columns.get_supported_columns = function(adapter_or_scheme)
					local adapter = type(adapter_or_scheme) == "string" and oil_config.get_adapter_by_scheme(adapter_or_scheme) or adapter_or_scheme
					local supported = orig_get_supported_columns(adapter_or_scheme)
					if not adapter or adapter.name ~= "p4" then
						return supported
					end

					-- Check if author column is already explicitly in supported
					local has_author = false
					for _, def in ipairs(supported) do
						local name = util.split_config(def)
						if name == "author" or name == "user" or name == "p4_user" then
							has_author = true
							break
						end
					end

					if not has_author then
						local found_buf
						for l = 2, 5 do
							local ok_loc, name, val = pcall(debug.getlocal, l, 1)
							if ok_loc and (name == "bufnr" or name == "buffer") and type(val) == "number" and val > 0 then
								found_buf = val
								break
							end
						end
						if not found_buf then
							local cur = vim.api.nvim_get_current_buf()
							if vim.api.nvim_buf_is_valid(cur) then
								found_buf = cur
							end
						end

						if found_buf and vim.api.nvim_buf_is_valid(found_buf) then
							local bufname = vim.api.nvim_buf_get_name(found_buf)
							local parsed = M.parse_url(bufname)
							if parsed and (not parsed.changelist or parsed.changelist == "history" or parsed.changelist == "opened") then
								local copy = vim.deepcopy(supported)
								table.insert(copy, "author")
								return copy
							end
						end
					end

					return supported
				end
			end

			local name_col = columns.get_column(nil, "name")
			if name_col and not name_col._p4_wrapped then
				name_col._p4_wrapped = true
				local orig_factory = name_col.create_sort_value_factory
				name_col.create_sort_value_factory = function(num_entries)
					local orig_fn = orig_factory(num_entries)
					return function(entry)
						local id = entry[1]
						local parent_url = id and cache.get_parent_url(id)
						if parent_url and (parent_url:match("^oil%-p4://") or parent_url:match("^p4://")) then
							local p = M.parse_url(parent_url)
							if not p.changelist or p.changelist == "opened" or p.changelist == "history" then
								local name = entry[2]
								if name == "default" then
									return "0_default"
								end
								local num = tonumber(name)
								if num then
									return string.format("1_%012d", 999999999999 - num)
								end
								return "2_" .. name
							end
						end
						return orig_fn(entry)
					end
				end
			end

			vim.api.nvim_set_hl(0, "OilP4ChangelistIcon", { link = "Special", default = true })

			pcall(require, "oil.adapters.files")
			local icon_col = columns.get_column(M, "icon")
			if icon_col and not icon_col._p4_wrapped then
				icon_col._p4_wrapped = true
				local orig_icon_render = icon_col.render
				icon_col.render = function(entry, conf, bufnr)
					local id = entry[1]
					local parent_url = id and cache.get_parent_url(id)
					if parent_url and (parent_url:match("^oil%-p4://") or parent_url:match("^p4://")) then
						local p = M.parse_url(parent_url)
						if not p.changelist or p.changelist == "opened" or p.changelist == "history" then
							local name = entry[2]
							if name ~= "opened" and name ~= "history" and name ~= ".." then
								local icon = (conf and conf.changelist) or ""
								local hl = (conf and conf.changelist_hl) or "OilP4ChangelistIcon"
								if conf and conf.highlight and not (conf and conf.changelist_hl) then
									hl = conf.highlight
								end
								if type(hl) == "function" then
									hl = hl(icon)
								end
								if not conf or conf.add_padding ~= false then
									icon = icon .. " "
								end
								return { icon, hl }
							end
						end
					end
					return orig_icon_render(entry, conf, bufnr)
				end
			end
		end
	end

	register()

	if not oil_config._p4_hooked then
		oil_config._p4_hooked = true
		local orig_setup = oil_config.setup
		oil_config.setup = function(opts)
			local ret = orig_setup(opts)
			register()
			return ret
		end
	end

	package.preload["oil.adapters.p4"] = function()
		return M
	end

	vim.filetype.add({
		pattern = {
			["oil%-p4://.*"] = { "oil", { priority = 10 } },
			["p4://change/.*"] = { "perforce", { priority = 20 } },
			["p4://.*"] = { "oil", { priority = 10 } },
		},
	})

	local aug = vim.api.nvim_create_augroup("perforce-oil-adapter", { clear = true })
	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = aug,
		pattern = "oil-p4://*,p4://*",
		nested = true,
		callback = function(params)
			if params.file:match("^p4://change/") or params.file:match("^oil%-p4://change/") then
				return
			end
			register()
			require("oil").load_oil_buffer(params.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = aug,
		pattern = "oil-p4://*,p4://*",
		nested = true,
		callback = function(params)
			local bufname = vim.api.nvim_buf_get_name(params.buf)
			if vim.endswith(bufname, "/") then
				vim.cmd.doautocmd({ args = { "BufWritePre", params.file }, mods = { silent = true } })
				require("oil").save(nil, function(err)
					if err and err ~= "Canceled" then
						vim.notify(err, vim.log.levels.ERROR)
					end
				end)
			elseif bufname:match("^p4://change/") or bufname:match("^oil%-p4://change/") then
				M.write_file(params.buf)
			end
		end,
	})
end

---Re-render all active oil-p4 and p4 buffers with refetch
function M.rerender_all_p4_buffers()
	local ok_view, oil_view = pcall(require, "oil.view")
	if not ok_view then
		return
	end
	local ok_oil, oil_plugin = pcall(require, "perforce.plugins.oil")
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "oil" then
			local bname = vim.api.nvim_buf_get_name(b)
			if bname:match("^oil%-p4://") or bname:match("^p4://") then
				oil_view.render_buffer_async(b, { refetch = true }, function(err)
					if not err and vim.api.nvim_buf_is_valid(b) and ok_oil then
						oil_plugin.refresh(b)
					end
				end)
			elseif ok_oil then
				oil_plugin.refresh(b)
			end
		end
	end
end

---Write non-directory buffer (e.g. changelist spec p4://change/<cl>)
---@param bufnr integer
function M.write_file(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.bo[bufnr].modified then
		return
	end
	local bufname = vim.api.nvim_buf_get_name(bufnr)
	local cl = bufname:match("^p4://change/([^/]+)") or bufname:match("^oil%-p4://change/([^/]+)")
	if cl then
		local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local input = table.concat(cur_lines, "\n")
		local save_err, save_msg = perforce.save_change_spec(input)
		if save_err then
			local err_str = type(save_err) == "table" and table.concat(save_err, "\n") or tostring(save_err)
			vim.notify("[perforce] " .. err_str, vim.log.levels.ERROR)
			error(err_str)
		else
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.bo[bufnr].modified = false
			end
			vim.notify(save_msg or string.format("Changelist %s updated", cl), vim.log.levels.INFO)
			M.rerender_all_p4_buffers()
		end
		return
	end
	error("Unsupported file write: " .. bufname)
end

return M
