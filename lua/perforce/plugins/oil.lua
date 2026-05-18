local perforce = require("perforce")
local oil = require("oil")
local namespace = vim.api.nvim_create_namespace("perforce-oil")

local M = {}

local function get_oil_buffer_path(buffer)
	local oil_url = vim.api.nvim_buf_get_name(buffer)
	local file_url = oil_url:gsub("^oil", "file")
	if vim.fn.has("win32") == 1 then
		file_url = file_url:gsub("file:///([A-Za-z])/", "file:///%1:/")
	end
	return vim.uri_to_fname(file_url)
end

local function add_status_extmarks(buffer, status_map)
	vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)

	for n = 1, vim.api.nvim_buf_line_count(buffer) do
		local entry = oil.get_entry_on_line(buffer, n)
		if entry and entry.name ~= ".." then
			local status = status_map[entry.name]
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
		end
	end
end

function M.refresh(buffer)
	if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
		return
	end

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

function M.setup()
	vim.api.nvim_create_autocmd("User", {
		pattern = "OilEnter",
		callback = function(args)
			M.refresh(args.data.buf)
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
