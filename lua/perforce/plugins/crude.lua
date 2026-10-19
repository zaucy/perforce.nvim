---Perforce integration for crude.nvim. Nothing is registered automatically; wire it up yourself:
---
---  local crude = require("crude")
---  local p4_crude = require("perforce.plugins.crude")
---  crude.register_provider("perforce", p4_crude.provider)         -- or p4_crude.provider({ ... })
---  crude.register_extension("crude-fs-p4", p4_crude.fs_signs)     -- or p4_crude.fs_signs({ ... })
local perforce = require("perforce")
local p4 = require("perforce.plugins.crude.p4")
local url = require("perforce.plugins.crude.url")

local M = {}

---crude.Provider for p4:// buffers (callable: `M.provider(opts)` creates a configured instance)
M.provider = require("perforce.plugins.crude.provider")

---crude.Extension for crude-fs opened-file signs (callable: `M.fs_signs(opts)` creates a configured instance)
M.fs_signs = require("perforce.plugins.crude.fs_signs")

M.url = url

---Open a p4:// crude buffer
---@param target? string|number "opened", "history", "pending", "default", a changelist number, or a full p4:// URL
function M.open(target)
	local name
	if target == nil or tostring(target) == "" then
		name = url.scheme
	else
		target = tostring(target)
		name = target:match("^p4://") and target or (url.scheme .. target)
	end
	url.parse(name) -- validate
	vim.cmd.edit(vim.fn.fnameescape(name))
end

---Refresh loaded, unmodified p4:// crude buffers (e.g. after a description change)
function M.refresh_buffers()
	local ok, crude = pcall(require, "crude")
	if not ok then
		return
	end
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_loaded(b)
			and vim.bo[b].filetype == "crude"
			and not vim.bo[b].modified
			and url.try_parse(vim.api.nvim_buf_get_name(b))
		then
			pcall(crude.refresh_buffer, b)
		end
	end
end

---Crude entry on the cursor line of a crude buffer (nil on header lines / non-crude buffers)
---@param bufnr? integer
---@return crude.Entry?
function M.cursor_entry(bufnr)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	if vim.bo[bufnr].filetype ~= "crude" then
		return nil
	end
	local ok_cache, cache = pcall(require, "crude.cache")
	local ok_diff, diff = pcall(require, "crude.diff")
	if not ok_cache or not ok_diff then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	if not line or line:match("^#") then
		return nil
	end
	local prov = cache.get_buf_provider(bufnr)
	local ok, id = pcall(diff.parse_line, line, prov, bufnr)
	local snapshot = cache.get_snapshot(bufnr)
	return (ok and id and snapshot) and cache.lookup(snapshot, id) or nil
end

---@param buf integer
---@param cl_str string
---@param opts { vertical?: boolean, split?: boolean }
---@return integer win
local function open_change_window(buf, cl_str, opts)
	if opts.vertical then
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, buf)
		return vim.api.nvim_get_current_win()
	elseif opts.split then
		vim.cmd("split")
		vim.api.nvim_win_set_buf(0, buf)
		return vim.api.nvim_get_current_win()
	end

	local editor_width = vim.o.columns
	local editor_height = vim.o.lines - vim.o.cmdheight
	local width = math.min(math.max(math.floor(editor_width * 0.8), 70), editor_width - 4)
	local height = math.min(math.max(math.floor(editor_height * 0.8), 20), editor_height - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((editor_height - height) / 2)),
		col = math.max(0, math.floor((editor_width - width) / 2)),
		style = "minimal",
		border = "rounded",
		title = string.format(" Perforce Change: %s ", cl_str),
		title_pos = "center",
	})
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	return win
end

---Open a changelist specification editor (`p4 change -o` / `p4 change -i`) in `p4-change://<cl>`.
---Without a changelist, uses the current p4://<cl> buffer, or the changelist under the cursor in an overview.
---@param changelist? string|number
---@param opts? { vertical?: boolean, split?: boolean } default: centered float
function M.open_change(changelist, opts)
	opts = opts or {}

	if not changelist or tostring(changelist) == "" then
		local cur = url.try_parse(vim.api.nvim_buf_get_name(0))
		if cur and cur.kind == "changelist" then
			changelist = cur.changelist
		elseif cur then
			local entry = M.cursor_entry(0)
			if entry and entry.meta and entry.meta.changelist then
				changelist = entry.meta.changelist
			end
		end
	end

	local cl_str = (changelist and tostring(changelist) ~= "") and tostring(changelist) or "default"
	local bufname = "p4-change://" .. cl_str

	local existing = vim.fn.bufnr(bufname)
	if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) == existing then
				vim.api.nvim_set_current_win(win)
				return
			end
		end
		open_change_window(existing, cl_str, opts)
		return
	end

	perforce.change_spec(cl_str, function(err, spec)
		if err then
			vim.notify("[perforce] " .. (type(err) == "table" and table.concat(err, "\n") or tostring(err)), vim.log.levels.ERROR)
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
		local lines = vim.split(spec, "\r?\n")
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
			if vim.bo[buf].modified and vim.fn.confirm("Discard changelist edits?", "&Yes\n&No", 2) ~= 1 then
				return
			end
			pcall(vim.api.nvim_win_close, 0, true)
		end, { buffer = buf, desc = "Close changelist spec" })

		vim.api.nvim_create_autocmd("BufWriteCmd", {
			buffer = buf,
			callback = function()
				if not vim.bo[buf].modified then
					return
				end
				local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
				perforce.save_change_spec(content, function(save_err, msg)
					if save_err then
						vim.notify("[perforce] Failed to save change spec: " .. tostring(save_err), vim.log.levels.ERROR)
						return
					end
					if vim.api.nvim_buf_is_valid(buf) then
						vim.bo[buf].modified = false
					end
					vim.notify("[perforce] " .. (msg or "Change spec saved"), vim.log.levels.INFO)
					p4.emit_opened_changed({ changelist = cl_str })
					M.refresh_buffers()
				end)
			end,
		})
	end)
end

return M
