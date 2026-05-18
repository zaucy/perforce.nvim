local perforce = require("perforce")
local namespace = vim.api.nvim_create_namespace("perforce-signs")

local M = {}

local cache = {} -- bufnr -> { base_content = string, hunks = table, timer = timer }

local function update_signs(bufnr)
	if not cache[bufnr] or not cache[bufnr].base_content then
		return
	end

	local buf_content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local base_content = cache[bufnr].base_content

	local diff = vim.diff(base_content, buf_content, { result_type = "indices" })

	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

	local hunks = {}
	for _, hunk in ipairs(diff) do
		local start_a, count_a, start_b, count_b = unpack(hunk)
		table.insert(hunks, {
			removed = { start = start_a, count = count_a },
			added = { start = start_b, count = count_b },
		})

		if count_a > 0 and count_b > 0 then
			for i = 0, count_b - 1 do
				vim.api.nvim_buf_set_extmark(bufnr, namespace, start_b + i - 1, 0, {
					sign_text = "~",
					sign_hl_group = "DiffChange",
					priority = 10,
				})
			end
		elseif count_a > 0 then
			local line = math.max(0, start_b - 1)
			vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
				sign_text = "-",
				sign_hl_group = "DiffDelete",
				priority = 10,
			})
		elseif count_b > 0 then
			for i = 0, count_b - 1 do
				vim.api.nvim_buf_set_extmark(bufnr, namespace, start_b + i - 1, 0, {
					sign_text = "+",
					sign_hl_group = "DiffAdd",
					priority = 10,
				})
			end
		end
	end
	cache[bufnr].hunks = hunks
end

local function debounce_update(bufnr)
	if not cache[bufnr] then
		return
	end
	if cache[bufnr].timer then
		cache[bufnr].timer:stop()
	else
		cache[bufnr].timer = vim.uv.new_timer()
	end
	cache[bufnr].timer:start(100, 0, vim.schedule_wrap(function()
		if vim.api.nvim_buf_is_valid(bufnr) then
			update_signs(bufnr)
		end
	end))
end

function M.attach(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if cache[bufnr] then
		return
	end

	local file = vim.api.nvim_buf_get_name(bufnr)
	if file == "" or vim.bo[bufnr].buftype ~= "" then
		return
	end

	perforce.get_workspace_root(file, function(root)
		if not root then
			return
		end

		perforce.print({ file = file .. "#have" }, function(errors, content)
			if content then
				cache[bufnr] = { base_content = content, hunks = {} }
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(bufnr) then
						update_signs(bufnr)
						vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
							buffer = bufnr,
							callback = function()
								debounce_update(bufnr)
							end,
						})
					end
				end)
			end
		end)
	end)
end

function M.blame_line()
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = cursor[1]
	local file = vim.api.nvim_buf_get_name(bufnr)

	perforce.annotate({ file = file }, function(errors, list)
		if list and list[line] then
			local entry = list[line]
			vim.schedule(function()
				vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, {
					virt_text = { { "  " .. entry.lower .. " (CL)", "Comment" } },
					virt_text_pos = "eol",
					hl_mode = "combine",
				})
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(bufnr) then
						vim.api.nvim_buf_clear_namespace(bufnr, namespace, line - 1, line)
						update_signs(bufnr) -- restore signs
					end
				end, 5000)
			end)
		end
	end)
end

function M.diffthis()
	local bufnr = vim.api.nvim_get_current_buf()
	local file = vim.api.nvim_buf_get_name(bufnr)
	if not cache[bufnr] or not cache[bufnr].base_content then
		return
	end

	local base_content = cache[bufnr].base_content
	vim.cmd("vsplit")
	local scratch = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.split(base_content, "\n"))
	vim.api.nvim_buf_set_name(scratch, "perforce://base/" .. vim.fn.fnamemodify(file, ":t"))
	vim.api.nvim_win_set_buf(0, scratch)

	vim.cmd("diffthis")
	vim.cmd("wincmd p")
	vim.cmd("diffthis")
end

function M.next_hunk()
	local bufnr = vim.api.nvim_get_current_buf()
	if not cache[bufnr] or not cache[bufnr].hunks then
		return
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	for _, hunk in ipairs(cache[bufnr].hunks) do
		if hunk.added.start > line then
			vim.api.nvim_win_set_cursor(0, { hunk.added.start, 0 })
			return
		end
	end
end

function M.prev_hunk()
	local bufnr = vim.api.nvim_get_current_buf()
	if not cache[bufnr] or not cache[bufnr].hunks then
		return
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	for i = #cache[bufnr].hunks, 1, -1 do
		local hunk = cache[bufnr].hunks[i]
		if hunk.added.start < line then
			vim.api.nvim_win_set_cursor(0, { hunk.added.start, 0 })
			return
		end
	end
end

function M.setup()
	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
		callback = function(args)
			M.attach(args.buf)
		end,
	})
end

return M
