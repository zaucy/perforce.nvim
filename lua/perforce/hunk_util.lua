local M = {}

--- @class perforce.Hunk
--- @field start number
--- @field count number
--- @field added {start: number, count: number}
--- @field removed {start: number, count: number}
--- @field head string
--- @field lines string[]

--- @param str string
--- @return perforce.Hunk[]
function M.parse_hunks_str(str)
	local hunks = {}
	local lines = vim.split(str, "\n")
	local current_hunk = nil

	for _, line in ipairs(lines) do
		local a, b, c, d = line:match("^@@ %-(%d+),(%d+) %+(%d+),(%d+) @@")
		if not a then
			a, c = line:match("^@@ %-(%d+) %+(%d+) @@")
			if a then
				b, d = 1, 1
			end
		end

		if a then
			if current_hunk then
				table.insert(hunks, current_hunk)
			end
			current_hunk = {
				removed = { start = tonumber(a), count = tonumber(b) },
				added = { start = tonumber(c), count = tonumber(d) },
				head = line,
				lines = {},
			}
		elseif current_hunk then
			table.insert(current_hunk.lines, line)
		end
	end

	if current_hunk then
		table.insert(hunks, current_hunk)
	end

	return hunks
end

return M
