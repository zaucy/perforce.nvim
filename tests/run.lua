-- Standalone native test runner for perforce.nvim with crude.nvim integration
-- Execute via: nvim --clean --headless -u NONE -l tests/run.lua

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local repo_dir = vim.fn.fnamemodify(script_dir, ":h")

-- Add perforce.nvim to package.path and rtp
package.path = repo_dir .. "/lua/?.lua;" .. repo_dir .. "/lua/?/init.lua;" .. script_dir .. "/?.lua;" .. package.path
vim.opt.rtp:prepend(repo_dir)

-- Locate crude.nvim sibling repository
local crude_dir = vim.fn.fnamemodify(repo_dir .. "/../crude.nvim", ":p")
if vim.fn.isdirectory(crude_dir) == 1 then
	package.path = crude_dir .. "/lua/?.lua;" .. crude_dir .. "/lua/?/init.lua;" .. package.path
	vim.opt.rtp:prepend(crude_dir)
end

local helper = require("test_helper")

-- Load test specs
require("crude_provider_spec")

-- Run tests and exit with code
local exit_code = helper.run_all()
os.exit(exit_code)
