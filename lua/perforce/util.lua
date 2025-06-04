local M = {}

---@class PerforceExecuteOptions
---@field cmd string
---@field args string[]
---@field callback fun(v: any[])

---@param opts PerforceExecuteOptions
function M.execute(opts)
	local args = { "-ztag", "-Mj", opts.cmd }
	vim.list_extend(args, opts.args)

	local stdout = vim.uv.new_pipe()
	assert(stdout, "failed to create stdout pipe")
	local stderr = vim.uv.new_pipe()
	assert(stderr, "failed to create stderr pipe")

	local result = {}

	vim.uv.spawn("p4", {
		args = args,
		stdio = { nil, stdout, stderr },
	}, function(code, _)
		if code == 0 then
			opts.callback(result)
		else
		end
	end)

	vim.uv.read_start(stdout, function(err, data)
		if data ~= nil then
			local lines = vim.split(data, "\n", { trimempty = true })
			for _, line in ipairs(lines) do
				local success, msg_or_err = pcall(vim.json.decode, line)
				if success then
					table.insert(result, msg_or_err)
				else
					vim.notify(string.format("%s while decoding %s", msg_or_err, line), vim.log.levels.ERROR)
				end
			end
		end
	end)

	vim.uv.read_start(stderr, function(err, data)
		if data ~= nil then
			local lines = vim.split(data, "\n", { trimempty = true })
			for _, line in ipairs(lines) do
				vim.notify(line, vim.log.levels.ERROR)
			end
		end
	end)
end

return M
