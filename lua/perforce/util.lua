local M = {}

---@class PerforceExecuteOptions
---@field cmd string
---@field args string[]
---@field callback fun(errors: any[]|nil, v: any[])

---@param opts PerforceExecuteOptions
function M.execute(opts)
	local args = { "-ztag", "-Mj", opts.cmd }
	vim.list_extend(args, opts.args)

	local stdout = vim.uv.new_pipe()
	assert(stdout, "failed to create stdout pipe")
	local stderr = vim.uv.new_pipe()
	assert(stderr, "failed to create stderr pipe")

	local result = {}
	local errors = {}
	local stdout_str = ""

	vim.uv.spawn("p4", {
		args = args,
		stdio = { nil, stdout, stderr },
	}, function(code, _)
		local lines = vim.split(stdout_str, "\n", { trimempty = true, plain = true })
		for _, line in ipairs(lines) do
			local success, msg_or_err = pcall(vim.json.decode, line)
			if success then
				table.insert(result, msg_or_err)
			else
				table.insert(errors, string.format("%s while decoding %s", msg_or_err, line))
			end
		end

		if #errors == 0 then
			errors = nil
		end
		if code == 0 then
			opts.callback(errors, result)
		else
		end
	end)

	vim.uv.read_start(stdout, function(err, data)
		if data ~= nil then
			stdout_str = stdout_str .. data
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
