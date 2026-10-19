---Async helpers shared by the perforce crude provider and the crude-fs signs extension.
---All functions that call p4 must run inside a `vim.async` task (crude runs provider hooks in one).
local perforce = require("perforce")

local M = {}

---Call a callback-style perforce API function (callback last) and await its result.
---Looks up nothing itself, so pass e.g. `perforce.opened` at call time (keeps test mocks working).
---@param fn function
---@param ... any arguments before the callback
---@return any errors
---@return any result
function M.call(fn, ...)
	local n = select("#", ...)
	local args = { ... }
	return vim.async.await(1, function(cb)
		args[n + 1] = cb
		fn(unpack(args, 1, n + 1))
	end)
end

---Records from a `p4 -ztag -Mj` result, excluding info/warning/error messages
---@param result any[]?
---@return table[]
function M.records(result)
	local out = {}
	for _, item in ipairs(result or {}) do
		if type(item) == "table" and item.severity == nil then
			table.insert(out, item)
		end
	end
	return out
end

---Extract a human readable error from a p4 result.
---p4 reports warnings (severity 2, e.g. "no such file(s)", "not in client view") with exit code 0, so mutating
---commands must treat them as failures too.
---@param errors any string[]|string|nil from perforce.* callbacks (non-zero exit / decode errors)
---@param result any[]? decoded -Mj messages
---@param min_severity? integer default 2
---@return string? message nil when there was no error
function M.error_message(errors, result, min_severity)
	min_severity = min_severity or 2
	local msgs = {}
	for _, item in ipairs(result or {}) do
		if type(item) == "table" and item.severity and tonumber(item.severity) >= min_severity and item.data then
			table.insert(msgs, vim.trim(tostring(item.data)))
		end
	end
	if #msgs == 0 and errors then
		if type(errors) == "table" then
			for _, e in ipairs(errors) do
				table.insert(msgs, tostring(e))
			end
		else
			table.insert(msgs, tostring(errors))
		end
	end
	if #msgs == 0 then
		return nil
	end
	return table.concat(msgs, "\n")
end

---Run a read-only p4 query and return only records. Raises on severity >= 3 errors.
---@param fn function
---@param ... any
---@return table[]
function M.query(fn, ...)
	local errors, result = M.call(fn, ...)
	local recs = M.records(result)
	local msg = M.error_message(errors, result, 3)
	if msg and #recs == 0 then
		error(msg, 0)
	end
	return recs
end

local client_info_cache = nil
local client_info_time = 0
local CLIENT_INFO_TTL = 30000

---Cached `p4 info` (30s TTL)
---@return table? info with clientName, userName, clientRoot, ...
function M.client_info()
	local now = vim.uv.now()
	if client_info_cache and (now - client_info_time) < CLIENT_INFO_TTL then
		return client_info_cache
	end
	local _, info = M.call(function(cb)
		perforce.info(cb)
	end)
	if type(info) == "table" and info.clientName then
		client_info_cache = info
		client_info_time = vim.uv.now()
	end
	return client_info_cache
end

---Clear the cached `p4 info` (tests)
function M.reset()
	client_info_cache = nil
	client_info_time = 0
end

---Resolve a depot (or client) path to a local filesystem path via `p4 where`
---@param path string
---@return string?
function M.local_path(path)
	if not path:match("^//") then
		return vim.fs.normalize(path)
	end
	local ok, recs = pcall(M.query, perforce.where, { path })
	if ok and recs[1] and recs[1].path then
		return vim.fs.normalize(recs[1].path)
	end
	return nil
end

---Notify all listeners that the set of opened files may have changed
---@param data? table
function M.emit_opened_changed(data)
	pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = "PerforceOpenedChanged",
		data = data or {},
	})
end

return M
