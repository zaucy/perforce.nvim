local perforce = require("perforce")
local oil = require("oil")
local adapter = require("perforce.plugins.oil.adapter")
local namespace = vim.api.nvim_create_namespace("perforce-oil")

local M = {}

local function wrap_oil_render()
	local ok_view, oil_view = pcall(require, "oil.view")
	if not ok_view or oil_view._p4_render_wrapped then
		return
	end
	oil_view._p4_render_wrapped = true

	local orig_render_buffer_async = oil_view.render_buffer_async
	oil_view.render_buffer_async = function(bufnr, opts, callback)
		local target = (bufnr == 0 or bufnr == nil) and vim.api.nvim_get_current_buf() or bufnr
		orig_render_buffer_async(bufnr, opts, function(err)
			if not err and vim.api.nvim_buf_is_valid(target) and vim.api.nvim_buf_is_loaded(target) then
				local bname = vim.api.nvim_buf_get_name(target)
				if bname:match("^oil%-p4://") or bname:match("^p4://") or vim.bo[target].filetype == "oil" then
					M.refresh(target)
				end
			end
			if callback then
				callback(err)
			end
		end)
	end
end

pcall(wrap_oil_render)

local function get_oil_buffer_path(buffer)
	local oil_url = vim.api.nvim_buf_get_name(buffer)
	local file_url = oil_url:gsub("^oil", "file")
	if vim.fn.has("win32") == 1 then
		file_url = file_url:gsub("file:///([A-Za-z])/", "file:///%1:/")
	end
	return vim.uri_to_fname(file_url)
end

local function add_status_extmarks(buffer, status_map, dir_map)
	vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)

	for n = 1, vim.api.nvim_buf_line_count(buffer) do
		local entry = oil.get_entry_on_line(buffer, n)
		if entry and entry.name ~= ".." then
			local status = status_map and status_map[entry.name]
			if status then
				local sign = " "
				local hl = "Normal"

				if status == "edit" then
					sign = "M"
					hl = "DiffChange"
				elseif status == "add" then
					sign = "A"
					hl = "DiffAdd"
				elseif status == "delete" then
					sign = "D"
					hl = "DiffDelete"
				elseif status == "unmodified" then
					sign = " "
					hl = "NonText"
				end

				if sign ~= " " then
					vim.api.nvim_buf_set_extmark(buffer, namespace, n - 1, 0, {
						sign_text = sign,
						sign_hl_group = hl,
						priority = 10,
					})
				end
			end

			if dir_map then
				local dname = dir_map[entry.name]
				if dname and dname ~= "" then
					vim.api.nvim_buf_set_extmark(buffer, namespace, n - 1, 0, {
						virt_text = { { "  " .. dname, "Comment" } },
						virt_text_pos = "eol",
						priority = 10,
					})
				end
			end
		end
	end
end

local function add_changelist_descriptions(buffer)
	vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)

	for n = 1, vim.api.nvim_buf_line_count(buffer) do
		local entry = oil.get_entry_on_line(buffer, n)
		if entry and entry.name ~= ".." then
			local desc = adapter.changelist_descriptions[entry.name]
			if desc and desc ~= "" then
				local first_line = vim.split(desc, "\n")[1]
				local virt_text
				local pending_match = first_line:match("^%*pending%*%s*(.*)$")
				if pending_match then
					if pending_match ~= "" then
						virt_text = {
							{ "  *pending* ", "DiagnosticWarn" },
							{ pending_match, "Comment" },
						}
					else
						virt_text = {
							{ "  *pending*", "DiagnosticWarn" },
						}
					end
				else
					virt_text = { { "  " .. first_line, "Comment" } }
				end
				vim.api.nvim_buf_set_extmark(buffer, namespace, n - 1, 0, {
					virt_text = virt_text,
					virt_text_pos = "eol",
					priority = 10,
				})
			end
		end
	end
end

---Refresh Perforce status marks and metadata for an Oil buffer
---@param buffer integer
function M.refresh(buffer)
	if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
		return
	end

	local bufname = vim.api.nvim_buf_get_name(buffer)

	-- Check if this is an oil-p4 buffer
	if bufname:match("^oil%-p4://") or bufname:match("^p4://") then
		local parsed = adapter.parse_url(bufname)
		if not parsed.changelist or parsed.changelist == "opened" or parsed.changelist == "history" then
			-- Root buffer, opened buffer, or history buffer: show changelist descriptions
			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(buffer) then
					add_changelist_descriptions(buffer)
				end
			end)
		else
			-- Changelist buffer: show file statuses and directory paths
			local norm = bufname:gsub("/+$", "")
			local status_map = adapter.status_map_by_url[norm] or adapter.status_map_by_url[norm .. "/"]
			local dir_map = adapter.dir_map_by_url[norm] or adapter.dir_map_by_url[norm .. "/"]
			if status_map then
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(buffer) then
						add_status_extmarks(buffer, status_map, dir_map)
					end
				end)
			else
				-- If not cached yet, re-query opened files for this changelist
				perforce.opened({ changelist = parsed.changelist }, function(_, opened_list)
					if opened_list and #opened_list > 0 then
						local _, smap, dmap = adapter.build_maps_from_opened(opened_list, parsed.changelist)
						adapter.status_map_by_url[norm] = smap
						adapter.status_map_by_url[norm .. "/"] = smap
						adapter.dir_map_by_url[norm] = dmap
						adapter.dir_map_by_url[norm .. "/"] = dmap
						vim.schedule(function()
							if vim.api.nvim_buf_is_valid(buffer) then
								add_status_extmarks(buffer, smap, dmap)
							end
						end)
					else
						-- Fallback to describe for submitted changelists
						perforce.describe(parsed.changelist, function(_, desc_info)
							if desc_info and desc_info.files and #desc_info.files > 0 then
								local _, smap, dmap = adapter.build_maps_from_describe(desc_info.files, parsed.changelist)
								adapter.status_map_by_url[norm] = smap
								adapter.status_map_by_url[norm .. "/"] = smap
								adapter.dir_map_by_url[norm] = dmap
								adapter.dir_map_by_url[norm .. "/"] = dmap
								vim.schedule(function()
									if vim.api.nvim_buf_is_valid(buffer) then
										add_status_extmarks(buffer, smap, dmap)
									end
								end)
							end
						end)
					end
				end)
			end
		end
		return
	end

	-- Standard oil filesystem buffer
	local path = get_oil_buffer_path(buffer)
	if not path then
		return
	end

	perforce.get_workspace_root(path, function(root)
		if not root then
			return
		end

		-- Use p4 fstat to get status of all files in the directory
		perforce.fstat({
			files = { path .. "*" },
			fields = { "clientFile", "action" },
		}, function(errors, fstat_list)
			local status_map = {}
			if fstat_list then
				for _, entry in ipairs(fstat_list) do
					if entry.clientFile then
						local filename = vim.fn.fnamemodify(entry.clientFile, ":t")
						status_map[filename] = entry.action or "unmodified"
					end
				end
			end

			vim.schedule(function()
				if vim.api.nvim_buf_is_valid(buffer) then
					add_status_extmarks(buffer, status_map)
				end
			end)
		end)
	end)
end

---Open an Oil buffer for Perforce changelists
---@param changelist string|number|nil Optional changelist number or "default"
function M.open(changelist)
	if changelist and tostring(changelist) ~= "" then
		oil.open("oil-p4://" .. tostring(changelist) .. "/")
	else
		oil.open("oil-p4://")
	end
end

local function open_change_window(buf, cl_str, opts)
	opts = opts or {}
	if opts.vertical then
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, buf)
		return vim.api.nvim_get_current_win()
	elseif opts.split then
		vim.cmd("split")
		vim.api.nvim_win_set_buf(0, buf)
		return vim.api.nvim_get_current_win()
	end

	-- Default: open in a centered floating window
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines - vim.o.cmdheight
	local width = math.min(math.max(math.floor(editor_width * 0.8), 70), editor_width - 4)
	local height = math.min(math.max(math.floor(editor_height * 0.8), 20), editor_height - 4)
	local row = math.max(0, math.floor((editor_height - height) / 2))
	local col = math.max(0, math.floor((editor_width - width) / 2))

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = string.format(" Perforce Change: %s ", cl_str),
		title_pos = "center",
	})

	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true

	return win
end

---Mark the file(s) under cursor or visual selection for edit (p4 edit) in Oil buffers
---@param callback? fun(err: string|nil, msg: string|nil)
function M.edit_cursor_file(callback)
	local mode = vim.fn.mode()
	local filepaths = {}
	local filenames = {}

	local dir = oil.get_current_dir()
	local bufname = vim.api.nvim_buf_get_name(0)
	local is_p4_buf = bufname:match("^oil%-p4://") or bufname:match("^p4://")
	local parsed = is_p4_buf and adapter.parse_url(bufname)

	local function add_entry(entry)
		if not entry or entry.name == ".." or entry.type == "directory" then
			return
		end
		local filepath
		if is_p4_buf and parsed and parsed.changelist then
			local key = parsed.changelist .. ":" .. entry.name
			filepath = adapter.file_clientfile_by_cl_and_name[key]
		elseif dir then
			filepath = vim.fs.normalize(vim.fs.joinpath(dir, entry.name))
		end
		if filepath then
			table.insert(filepaths, filepath)
			table.insert(filenames, entry.name)
		end
	end

	if mode:match("[vV]") then
		local start_line = vim.fn.line("v")
		local end_line = vim.fn.line(".")
		if start_line > end_line then
			start_line, end_line = end_line, start_line
		end
		for lnum = start_line, end_line do
			local entry = oil.get_entry_on_line(0, lnum)
			add_entry(entry)
		end
	else
		local ok_entry, entry = pcall(oil.get_cursor_entry)
		if ok_entry and entry then
			add_entry(entry)
		end
	end

	if #filepaths == 0 then
		vim.notify("[perforce] No file selected to edit", vim.log.levels.WARN)
		return
	end

	perforce.edit({ files = filepaths }, function(err, _)
		if err then
			local msg = type(err) == "table" and table.concat(err, "\n") or tostring(err)
			vim.notify("[perforce] " .. msg, vim.log.levels.ERROR)
			if callback then
				callback(msg, nil)
			end
		else
			local count_str = #filenames == 1 and filenames[1] or (#filenames .. " files")
			local msg = string.format("Opened %s for edit", count_str)
			vim.notify("[perforce] " .. msg, vim.log.levels.INFO)
			local cur_buf = vim.api.nvim_get_current_buf()
			if vim.api.nvim_buf_is_valid(cur_buf) then
				M.refresh(cur_buf)
			end
			if callback then
				callback(nil, msg)
			end
		end
	end)
end

---Open a changelist specification editor buffer (p4 change -o / -i)
---@param changelist string|number|nil Optional changelist number; if omitted, detects from current buffer or cursor entry
---@param opts? table Options: { vertical = boolean, split = boolean, terminal = boolean }
function M.open_change(changelist, opts)
	opts = opts or {}

	-- Detect changelist if not passed
	if not changelist or tostring(changelist) == "" then
		local bufname = vim.api.nvim_buf_get_name(0)
		if bufname:match("^oil%-p4://") or bufname:match("^p4://") then
			local parsed = adapter.parse_url(bufname)
			if parsed and parsed.changelist and parsed.changelist ~= "opened" and parsed.changelist ~= "history" then
				changelist = parsed.changelist
			else
				local ok_entry, entry = pcall(oil.get_cursor_entry)
				if ok_entry and entry and entry.name ~= ".." and entry.name ~= "opened" and entry.name ~= "history" then
					changelist = entry.name
				end
			end
		end
	end

	if not changelist or tostring(changelist) == "" then
		-- Contextual fallback: if in visual mode or cursor is on a file entry, run p4 edit!
		local mode = vim.fn.mode()
		if mode:match("[vV]") then
			M.edit_cursor_file()
			return
		end

		local ok_entry, entry = pcall(oil.get_cursor_entry)
		if ok_entry and entry and entry.name ~= ".." and entry.type == "file" then
			M.edit_cursor_file()
			return
		end

		vim.notify("[perforce] No changelist or file selected to edit", vim.log.levels.WARN)
		return
	end

	local cl_str = tostring(changelist)

	if opts.terminal then
		local cmd_str = opts.vertical and "vsplit" or "split"
		vim.cmd(cmd_str .. " | terminal p4 change " .. cl_str)
		return
	end

	local bufname = string.format("p4://change/%s", cl_str)
	local existing_buf = vim.fn.bufnr(bufname)
	if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == existing_buf then
				vim.api.nvim_set_current_win(win)
				return
			end
		end
		open_change_window(existing_buf, cl_str, opts)
		return
	end

	perforce.change_spec(cl_str, function(err, spec)
		if err then
			local msg = type(err) == "table" and table.concat(err, "\n") or tostring(err)
			vim.notify("[perforce] " .. msg, vim.log.levels.ERROR)
			return
		end

		if not spec or spec == "" then
			vim.notify("[perforce] Empty change specification returned for " .. cl_str, vim.log.levels.WARN)
			return
		end

		local buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, buf, bufname)
		vim.bo[buf].buftype = "acwrite"
		vim.bo[buf].filetype = "perforce"

		local lines = vim.split(spec, "\n")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modified = false

		local win = open_change_window(buf, cl_str, opts)

		for lnum, line in ipairs(lines) do
			if line:match("^Description:") then
				vim.api.nvim_win_set_cursor(win, { math.min(lnum + 1, #lines), 0 })
				break
			end
		end

		vim.keymap.set("n", "q", function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
				local choice = vim.fn.confirm("Discard changelist edits?", "&Yes\n&No", 2)
				if choice == 1 then
					pcall(vim.api.nvim_win_close, 0, true)
				end
			else
				pcall(vim.api.nvim_win_close, 0, true)
			end
		end, { buffer = buf, desc = "Close changelist spec floating window" })

		vim.api.nvim_create_autocmd("BufWriteCmd", {
			buffer = buf,
			callback = function()
				if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modified then
					return
				end
				adapter.write_file(buf)
			end,
		})
	end)
end

local function register_oil_action()
	local ok_actions, oil_actions = pcall(require, "oil.actions")
	if ok_actions and not oil_actions.p4_change then
		oil_actions.p4_change = {
			desc = "Edit Perforce changelist specification in a floating window",
			parameters = {
				vertical = {
					type = "boolean",
					desc = "Open the change spec in a vertical split instead of floating window",
				},
				split = {
					type = "boolean",
					desc = "Open the change spec in a horizontal split instead of floating window",
				},
				terminal = {
					type = "boolean",
					desc = "Open in a terminal window instead of a Neovim buffer",
				},
			},
			callback = function(action_opts)
				M.open_change(nil, action_opts)
			end,
		}
		oil_actions.p4_edit = {
			desc = "Mark file under cursor for edit (p4 edit)",
			callback = function()
				M.edit_cursor_file()
			end,
		}
	end
	wrap_oil_render()
end

register_oil_action()

function M.setup(opts)
	M.config = opts or {}
	adapter.setup()
	register_oil_action()
	wrap_oil_render()

	vim.api.nvim_create_autocmd("FileType", {
		pattern = "perforce",
		callback = function(ev)
			vim.bo[ev.buf].commentstring = "# %s"
			vim.cmd([[
				syntax match p4Comment "^#.*$"
				syntax match p4Header "^[A-Za-z]\+:"
				highlight default link p4Comment Comment
				highlight default link p4Header Keyword
			]])
		end,
	})

	vim.api.nvim_create_user_command("OilP4", function(cmd_opts)
		local arg = cmd_opts.args ~= "" and cmd_opts.args or nil
		if arg and arg:match("^change%s*(.*)$") then
			local target = arg:match("^change%s+(.*)$")
			M.open_change(target)
		else
			M.open(arg)
		end
	end, {
		nargs = "?",
		desc = "Open Oil buffer or edit change spec for Perforce changelists",
		complete = function(arg_lead)
			local candidates = { "opened", "history", "change", "default" }
			if adapter.pending_changelists then
				for _, cl in ipairs(adapter.pending_changelists) do
					if cl ~= "default" and cl ~= "opened" and cl ~= "history" and cl ~= "change" then
						table.insert(candidates, cl)
					end
				end
			end
			if arg_lead == "" then
				return candidates
			end
			local matches = {}
			for _, cand in ipairs(candidates) do
				if vim.startswith(cand, arg_lead) then
					table.insert(matches, cand)
				end
			end
			return matches
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "OilEnter",
		callback = function(args)
			M.refresh(args.data.buf)

			local bufname = vim.api.nvim_buf_get_name(args.data.buf)
			if (bufname:match("^oil%-p4://") or bufname:match("^p4://")) and M.config and M.config.keymaps then
				for lhs, act in pairs(M.config.keymaps) do
					if act == "change" or act == "p4_change" or lhs == "change" or lhs == "p4_change" then
						local key = (act == "change" or act == "p4_change") and lhs or act
						vim.keymap.set("n", key, function()
							M.open_change()
						end, { buffer = args.data.buf, desc = "Edit Perforce changelist (p4 change)" })
					end
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "OilMutationComplete",
		callback = function()
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "oil" then
					M.refresh(bufnr)
				end
			end
		end,
	})
end

return M
