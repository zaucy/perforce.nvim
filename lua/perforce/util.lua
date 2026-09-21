local M = {}

local workspace_cache = {} -- path -> { root = string|false, timestamp = number }
local CACHE_TTL = 1000 * 60 * 5 -- 5 minutes

---@class PerforceExecuteOptions
---@field cmd string
---@field args string[]
---@field callback fun(errors: any[]|nil, v: any[])
---@field cwd string|nil

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
		cwd = opts.cwd,
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
		vim.schedule(function()
			if code == 0 then
				opts.callback(errors, result)
			else
				opts.callback(errors or { "p4 exited with code " .. code }, result)
			end
		end)
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
				-- Only notify if not a "not in client view" style error which is common during detection
				if not line:match("not in client view") and not line:match("Connect to server failed") then
					vim.notify(line, vim.log.levels.ERROR)
				end
			end
		end
	end)
end

---Get the workspace root for a given path, with caching.
---@param path string
---@param callback fun(root: string|nil)
function M.get_workspace_root(path, callback)
	path = vim.fn.fnamemodify(path, ":p")
	if vim.fn.isdirectory(path) == 0 then
		path = vim.fn.fnamemodify(path, ":h")
	end

	-- Check cache
	local cached = workspace_cache[path]
	if cached and (vim.uv.now() - cached.timestamp < CACHE_TTL) then
		callback(cached.root or nil)
		return
	end

	-- Check for root markers to avoid calling p4 info on non-perforce projects
	local markers = vim.fs.find({ ".p4config", ".p4ignore", ".p4ignore.txt" }, {
		path = path,
		upward = true,
		stop = vim.uv.os_homedir(),
	})

	if #markers == 0 then
		workspace_cache[path] = { root = false, timestamp = vim.uv.now() }
		callback(nil)
		return
	end

	M.execute({
		cmd = "info",
		args = {},
		cwd = path,
		callback = function(errors, result)
			local root = nil
			if result and result[1] and result[1].clientRoot then
				root = result[1].clientRoot
			end

			workspace_cache[path] = { root = root or false, timestamp = vim.uv.now() }
			callback(root)
		end,
	})
end

return M
