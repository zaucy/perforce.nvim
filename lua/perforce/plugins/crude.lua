local perforce = require("perforce")
local provider = require("perforce.plugins.crude.provider")

local M = {}

M.provider = provider

---Open a Crude buffer for Perforce changelists
---@param changelist? string|number
function M.open(changelist)
	local ok_crude, crude = pcall(require, "crude")
	assert(ok_crude, "crude.nvim is required to use perforce.plugins.crude")

	if changelist and tostring(changelist) ~= "" then
		local target = tostring(changelist)
		if not target:match("^p4://") and not target:match("^perforce://") then
			target = "p4://" .. target
		end
		crude.open(target)
	else
		crude.open("p4://opened")
	end
end

---Open a change window (centered float or split)
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

	-- Centered floating window
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

---Open a changelist specification editor buffer (p4 change -o / -i)
---@param changelist? string|number
---@param opts? table Options: { vertical = boolean, split = boolean }
function M.open_change(changelist, opts)
	opts = opts or {}

	if not changelist or tostring(changelist) == "" then
		local bufname = vim.api.nvim_buf_get_name(0)
		local info = provider.parse_url(bufname)
		if info.changelist and info.changelist ~= "opened" and info.changelist ~= "history" then
			changelist = info.changelist
		end
	end

	local cl_str = (changelist and tostring(changelist) ~= "") and tostring(changelist) or "default"
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
				local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
				perforce.save_change_spec(content, function(save_err, msg)
					if save_err then
						vim.notify("[perforce] Failed to save change spec: " .. tostring(save_err), vim.log.levels.ERROR)
					else
						vim.bo[buf].modified = false
						vim.notify("[perforce] " .. (msg or "Change spec saved"), vim.log.levels.INFO)
					end
				end)
			end,
		})
	end)
end

---Setup crude.nvim integration for Perforce
---@param opts? table
function M.setup(opts)
	M.config = opts or {}

	-- Register provider with crude if available
	local ok_crude, crude = pcall(require, "crude")
	if ok_crude then
		crude.register_provider("perforce", {
			patterns = { "p4://*", "perforce://*" },
			columns = provider.columns,
			list = provider.list,
			apply = provider.apply,
			validate_entry_name = provider.validate_entry_name,
			render_entry = provider.render_entry,
			on_select = provider.on_select,
			on_parent = provider.on_parent,
		})
	end

	-- Perforce change spec syntax
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

	-- User commands
	local function create_p4_command(cmd_name)
		vim.api.nvim_create_user_command(cmd_name, function(cmd_opts)
			local arg = cmd_opts.args ~= "" and cmd_opts.args or nil
			if arg and arg:match("^change%s*(.*)$") then
				local target = arg:match("^change%s+(.*)$")
				M.open_change(target)
			else
				M.open(arg)
			end
		end, {
			nargs = "?",
			desc = "Open Crude buffer or edit change spec for Perforce changelists",
			complete = function(arg_lead)
				local candidates = { "opened", "history", "change", "default" }
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
	end

	create_p4_command("P4")
	create_p4_command("CrudeP4")
end

return M
