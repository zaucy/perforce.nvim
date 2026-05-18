local util = require("perforce.util")
local hunk_util = require("perforce.hunk_util")

local M = {}

---Get the workspace root for a given path, with caching.
---@param path string
---@param callback fun(root: string|nil)
function M.get_workspace_root(path, callback)
	util.get_workspace_root(path, callback)
end

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
				local info = msgs[i]
				local diff_msg = msgs[i + 1]

				assert(info.clientFile ~= nil, "missing clientFile in message")
				assert(diff_msg.data ~= nil, "missing diff msg data")

				info.hunks = hunk_util.parse_hunks_str(diff_msg.data)

				table.insert(result, info)
			end

			callback(errors, result)
		end,
	})
end

---@class PerforceFstatOptions
---@field files string[]|string
---@field fields string[]|nil

---@class PerforceFstatEntry
---@field clientFile string
---@field depotFile string
---@field headRev string
---@field haveRev string
---@field action string|nil
---@field change string|nil
---@field type string

---@param options PerforceFstatOptions
---@param callback fun(errors: string[]|nil, list: PerforceFstatEntry[]|nil)
function M.fstat(options, callback)
	local args = {}
	if options.fields then
		table.insert(args, "-T")
		table.insert(args, table.concat(options.fields, ","))
	end

	local files = options.files
	if type(files) == "string" then
		files = { files }
	end

	for _, file in ipairs(files) do
		table.insert(args, file)
	end

	util.execute({
		cmd = "fstat",
		args = args,
		callback = callback,
	})
end

---@class PerforcePrintOptions
---@field file string
---@field output_file string|nil

---@param options PerforcePrintOptions
---@param callback fun(errors: string[]|nil, content: string|nil)
function M.print(options, callback)
	local args = { "-q" }
	if options.output_file then
		table.insert(args, "-o")
		table.insert(args, options.output_file)
	end
	table.insert(args, options.file)

	util.execute({
		cmd = "print",
		args = args,
		callback = function(errors, msgs)
			if options.output_file then
				callback(errors, nil)
			else
				local content = ""
				for _, msg in ipairs(msgs) do
					if msg.data then
						content = content .. msg.data
					end
				end
				callback(errors, content)
			end
		end,
	})
end

---@class PerforceAnnotateOptions
---@field file string
---@field all boolean|nil
---@field follow_branches boolean|nil

---@class PerforceAnnotateEntry
---@field upper string
---@field lower string
---@field data string

---@param options PerforceAnnotateOptions
---@param callback fun(errors: string[]|nil, list: PerforceAnnotateEntry[]|nil)
function M.annotate(options, callback)
	local args = { "-q" }
	if options.all then
		table.insert(args, "-a")
	end
	if options.follow_branches then
		table.insert(args, "-i")
	end
	table.insert(args, options.file)

	util.execute({
		cmd = "annotate",
		args = args,
		callback = callback,
	})
end

return M
