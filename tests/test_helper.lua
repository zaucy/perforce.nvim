local M = {}

local current_suite = ""
local test_cases = {}
local passed_count = 0
local failed_count = 0
local failures = {}

---Deep equality check for Lua values
---@param a any
---@param b any
---@return boolean
local function deep_equals(a, b)
	if a == b then
		return true
	end
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return false
	end

	local keys = {}
	for k, v in pairs(a) do
		keys[k] = true
		if not deep_equals(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if not keys[k] then
			return false
		end
	end
	return true
end

---Format value for error message
---@param val any
---@return string
local function format_val(val)
	if type(val) == "string" then
		return string.format("%q", val)
	elseif type(val) == "table" then
		return vim.inspect(val, { newline = " ", indent = "" })
	else
		return tostring(val)
	end
end

M.assert = {
	are_equal = function(expected, actual, msg)
		if expected ~= actual then
			local m = msg or string.format("Expected %s, but got %s", format_val(expected), format_val(actual))
			error(m, 2)
		end
	end,

	are_not_equal = function(expected, actual, msg)
		if expected == actual then
			local m = msg or string.format("Expected values not to equal %s", format_val(expected))
			error(m, 2)
		end
	end,

	same = function(expected, actual, msg)
		if not deep_equals(expected, actual) then
			local m = msg or string.format("Deep equality failed.\nExpected: %s\nActual:   %s", format_val(expected), format_val(actual))
			error(m, 2)
		end
	end,

	is_true = function(val, msg)
		if val ~= true then
			error(msg or string.format("Expected true, got %s", format_val(val)), 2)
		end
	end,

	is_false = function(val, msg)
		if val ~= false then
			error(msg or string.format("Expected false, got %s", format_val(val)), 2)
		end
	end,

	is_nil = function(val, msg)
		if val ~= nil then
			error(msg or string.format("Expected nil, got %s", format_val(val)), 2)
		end
	end,

	is_not_nil = function(val, msg)
		if val == nil then
			error(msg or "Expected not nil, got nil", 2)
		end
	end,

	truthy = function(val, msg)
		if not val then
			error(msg or string.format("Expected truthy, got %s", format_val(val)), 2)
		end
	end,

	matches = function(pattern, str, msg)
		if type(str) ~= "string" or not str:match(pattern) then
			error(msg or string.format("Expected %s to match pattern %q", format_val(str), pattern), 2)
		end
	end,

	has_error = function(fn, expected_msg_pattern)
		local ok, err = pcall(fn)
		if ok then
			error("Expected function to raise an error, but it succeeded", 2)
		end
		if expected_msg_pattern and not tostring(err):match(expected_msg_pattern) then
			error(string.format("Expected error to match pattern %q, but got %s", expected_msg_pattern, tostring(err)), 2)
		end
	end,
}

---Define a test suite
---@param name string
---@param fn fun()
function M.describe(name, fn)
	local prev_suite = current_suite
	current_suite = (prev_suite ~= "") and (prev_suite .. " > " .. name) or name
	fn()
	current_suite = prev_suite
end

---Define a test case
---@param name string
---@param fn fun()
function M.it(name, fn)
	table.insert(test_cases, {
		suite = current_suite,
		name = name,
		fn = fn,
	})
end

---Reset test cases
function M.reset()
	test_cases = {}
	passed_count = 0
	failed_count = 0
	failures = {}
	current_suite = ""
end

---Run all registered test cases
---@return integer exit_code
function M.run_all()
	local start_time = vim.uv.hrtime()
	print("\n=== Running perforce.nvim Test Suite ===")

	local current_printed_suite = nil

	for _, test in ipairs(test_cases) do
		if test.suite ~= current_printed_suite then
			print(string.format("\n[%s]", test.suite))
			current_printed_suite = test.suite
		end

		local test_start = vim.uv.hrtime()
		local ok = false
		local err = nil

		-- Run via vim.async task
		local task = vim.async.run(function()
			test.fn()
		end)

		local completed = false
		task:on_complete(function(task_err)
			if task_err then
				ok = false
				err = task_err
			else
				ok = true
			end
			completed = true
		end)

		-- Poll until completed
		vim.wait(5000, function()
			return completed
		end, 5)

		local duration_ms = (vim.uv.hrtime() - test_start) / 1000000

		if ok then
			passed_count = passed_count + 1
			print(string.format("  ✓ %s (%.2fms)", test.name, duration_ms))
		else
			failed_count = failed_count + 1
			print(string.format("  ✗ %s (%.2fms)", test.name, duration_ms))
			table.insert(failures, {
				suite = test.suite,
				name = test.name,
				err = err,
			})
		end
	end

	local total_duration_ms = (vim.uv.hrtime() - start_time) / 1000000
	print("\n-----------------------------------------")
	print(string.format("Results: %d passed, %d failed in %.2fms", passed_count, failed_count, total_duration_ms))

	if #failures > 0 then
		print("\nFailures:")
		for i, fail in ipairs(failures) do
			print(string.format("\n%d) [%s] %s:", i, fail.suite, fail.name))
			print(string.format("   %s", tostring(fail.err)))
		end
		print("\nTESTS FAILED\n")
		return 1
	else
		print("\nALL TESTS PASSED\n")
		return 0
	end
end

-- Make M.assert callable
local native_assert = assert
setmetatable(M.assert, {
	__call = function(_, cond, msg)
		return native_assert(cond, msg)
	end,
})

_G.describe = M.describe
_G.it = M.it
_G.assert = M.assert

return M
