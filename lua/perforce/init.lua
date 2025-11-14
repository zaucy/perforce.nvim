local util = require("perforce.util")
local hunk_util = require("perforce.hunk_util")

local M = {}

---@class PerforceClientInfo
---@field Access string
---@field Backup string
---@field Description string
---@field Host string
---@field LineEnd string
---@field Options string
---@field Owner string
---@field Root string
---@field SubmitOptions string
---@field Type string
---@field Update string
---@field client string

---@class PerforceClientOptions
---@field user string|nil
---@field user_case_insensitive boolean|nil
---@field name_filter string|nil
---@field max number|nil

---Get a list of perforce clients
---@param options PerforceClientOptions
---@param callback fun(list: PerforceClientInfo[]|nil)
function M.clients(options, callback)
	local args = {}
	if options.user then
		table.insert(args, "-u")
	end
	if options.user_case_insensitive then
		table.insert(args, "--user-case-insensitive")
	end
	if options.name_filter then
		table.insert(args, "-e")
		table.insert(args, options.name_filter)
	end
	if options.max then
		table.insert(args, "-m")
		table.insert(args, tostring(options.name_filter))
	end
	util.execute({
		cmd = "workspaces",
		args = args,
		callback = callback,
	})
end

---alias for perforce.clients()
---@param options PerforceClientOptions
---@param callback fun(list: PerforceClientInfo[]|nil)
function M.workspaces(options, callback)
	M.clients(options, callback)
end

---@class PerforceChangeInfo
---@field change string
---@field changeType string
---@field client string
---@field desc string
---@field path string
---@field status string
---@field time string
---@field user string

---@class PerforceChangesOptions
---@field files string[]|nil
---@field client string|nil
---@field client_case_insensitive boolean|nil
---@field user string|nil
---@field user_case_insensitive boolean|nil
---@field status string|nil

---Get list of pending and submitted changelists
---@param options PerforceChangesOptions
---@param callback fun(errors: string[]|nil, list: PerforceChangeInfo[]|nil)
function M.changes(options, callback)
	local args = {}

	if options.status then
		table.insert(args, "-s")
		table.insert(args, options.status)
	end

	if options.user then
		table.insert(args, "-u")
		table.insert(args, options.user)
	end

	if options.files then
		for _, file in ipairs(options.files) do
			assert(not vim.startswith(file, "-"))
			table.insert(args, file)
		end
	end

	util.execute({
		cmd = "changes",
		args = args,
		callback = callback,
	})
end

---@class PerforceOpenedArgs
---@field files string[]|nil
---@field changelist string|nil
---@field all_clients boolean|nil
---@field user string|nil

---@class PerforceOpenedEntry
---@field edit string
---@field change string
---@field client string
---@field clientFile string
---@field depotFile string
---@field haveRev string
---@field rev string
---@field type string
---@field user string

---@param options PerforceOpenedArgs
---@param callback fun(errors: string[]|nil, list: PerforceOpenedEntry[]|nil)
function M.opened(options, callback)
	local args = {}

	if options.files then
		for _, file in ipairs(options.files) do
			assert(not vim.startswith(file, "-"))
			table.insert(args, file)
		end
	end

	if options.changelist then
		table.insert(args, "-c")
		table.insert(args, options.changelist)
	end

	if options.all_clients then
		table.insert(args, "-as")
	end

	if options.user then
		table.insert(args, "-u")
		table.insert(args, options.user)
	end

	util.execute({
		cmd = "opened",
		args = args,
		callback = callback,
	})
end

---alias for perforce.changes()
---@param options PerforceChangesOptions
---@param callback fun(errors: string[]|nil, list: PerforceChangeInfo[]|nil)
function M.changelists(options, callback)
	M.changes(options, callback)
end

---@class PerforceWhereInfo
---@field clientFile string
---@field depotFile string
---@field path string

---@param files string[]
---@param callback fun(errors: string[]|nil, list: PerforceWhereInfo[]|nil)
function M.where(files, callback)
	local args = {}

	assert(#files > 0)

	if files then
		for _, file in ipairs(files) do
			assert(type(file) == "string")
			table.insert(args, file)
		end
	end

	util.execute({
		cmd = "where",
		args = args,
		callback = callback,
	})
end

--- @class PerforceDiffInfo
--- @field clientFile string
--- @field depotFile string
--- @field rev string
--- @field type string
--- @field hunks perforce.Hunk[]

--- @param files string[]|string
--- @param callback fun(errors: string[]|nil, list: PerforceDiffInfo[]|nil)
function M.diff(files, callback)
	local args = { "-du" }

	if type(files) == "string" then
		files = { files }
	end

	if files then
		for _, file in ipairs(files) do
			assert(not vim.startswith(file, "-"))
			table.insert(args, file)
		end
	end

	util.execute({
		cmd = "diff",
		args = args,
		callback = function(errors, msgs)
			local result = {}

			for i = 1, #msgs, 2 do
				local msg = msgs[i]
				local diff_msg = msgs[i + 1]

				assert(msg.clientFile ~= nil, "missing clientFile in message")
				assert(diff_msg.data ~= nil, "missing diff msg data")

				local info = vim.json.decode(msg)
				local hunks_str = vim.json.decode(diff_msg).data
				info.hunks = hunk_util.parse_hunks_str(hunks_str)

				table.insert(result, info)
			end

			callback(errors, result)
		end,
	})
end

return M
