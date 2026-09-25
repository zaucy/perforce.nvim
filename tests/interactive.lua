-- Interactive test environment for perforce.nvim with crude.nvim
-- Launched via: nu test.nu

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

local perforce = require("perforce")
local crude = require("crude")
local p4_crude = require("perforce.plugins.crude")

-- Mock in-memory Perforce depot data for interactive demo
local mock_store = {
	default = {
		{
			depotFile = "//depot/core/src/server.cpp",
			action = "edit",
			change = "default",
			type = "text",
			rev = "4",
		},
		{
			depotFile = "//depot/core/include/server.h",
			action = "edit",
			change = "default",
			type = "text",
			rev = "2",
		},
		{
			depotFile = "//depot/core/docs/architecture.md",
			action = "add",
			change = "default",
			type = "text",
			rev = "1",
		},
	},
	["10492"] = {
		{
			depotFile = "//depot/engine/renderer/vulkan_pipeline.cpp",
			action = "edit",
			change = "10492",
			type = "text",
			rev = "12",
		},
		{
			depotFile = "//depot/engine/shaders/pbr.hlsl",
			action = "add",
			change = "10492",
			type = "text",
			rev = "1",
		},
		{
			depotFile = "//depot/engine/textures/legacy_bump.png",
			action = "delete",
			change = "10492",
			type = "binary",
			rev = "5",
		},
	},
}

local mock_descriptions = {
	default = "Default changelist",
	["10492"] = "Upgrade graphics backend to Vulkan 1.3 and modern PBR pipeline",
}

-- Mock Perforce API functions for seamless standalone demo
perforce.info = function(callback)
	vim.schedule(function()
		callback(nil, {
			clientName = "demo_client",
			userName = "demo_developer",
			clientRoot = "C:/workspace/demo",
		})
	end)
end

perforce.opened = function(opts, callback)
	vim.schedule(function()
		opts = opts or {}
		if opts.changelist then
			local cl = tostring(opts.changelist)
			callback(nil, mock_store[cl] or {})
		else
			local all = {}
			for cl, files in pairs(mock_store) do
				for _, f in ipairs(files) do
					table.insert(all, f)
				end
			end
			callback(nil, all)
		end
	end)
end

perforce.changes = function(opts, callback)
	vim.schedule(function()
		local list = {}
		for cl, desc in pairs(mock_descriptions) do
			if cl ~= "default" then
				table.insert(list, {
					change = cl,
					user = "demo_developer",
					status = "pending",
					desc = desc,
				})
			end
		end
		callback(nil, list)
	end)
end

perforce.reopen = function(opts, callback)
	vim.schedule(function()
		local target_cl = tostring(opts.changelist)
		mock_store[target_cl] = mock_store[target_cl] or {}

		for _, file in ipairs(opts.files) do
			-- Remove from existing changelist
			for cl, list in pairs(mock_store) do
				for i = #list, 1, -1 do
					if list[i].depotFile == file then
						table.remove(list, i)
					end
				end
			end
			-- Add to target changelist
			table.insert(mock_store[target_cl], {
				depotFile = file,
				action = "edit",
				change = target_cl,
			})
		end
		callback(nil, { { action = "reopened" } })
	end)
end

perforce.move = function(opts, callback)
	vim.schedule(function()
		local cl = tostring(opts.changelist)
		local list = mock_store[cl] or {}
		for _, item in ipairs(list) do
			if item.depotFile == opts.from_file then
				item.depotFile = opts.to_file
			end
		end
		callback(nil, { { action = "moved" } })
	end)
end

perforce.revert = function(opts, callback)
	vim.schedule(function()
		local cl = tostring(opts.changelist)
		local list = mock_store[cl] or {}
		for _, f in ipairs(opts.files) do
			for i = #list, 1, -1 do
				if list[i].depotFile == f then
					table.remove(list, i)
				end
			end
		end
		callback(nil, { { action = "reverted" } })
	end)
end

perforce.change_spec = function(cl, callback)
	vim.schedule(function()
		local cl_str = tostring(cl or "default")
		local desc = mock_descriptions[cl_str] or "Work in progress"
		local files_str = ""
		for _, item in ipairs(mock_store[cl_str] or {}) do
			files_str = files_str .. string.format("\t%s\t# %s\n", item.depotFile, item.action)
		end

		local spec = string.format([[# A Perforce Change Specification.
Change:	%s

Client:	demo_client

User:	demo_developer

Status:	pending

Description:
	%s

Files:
%s]], cl_str, desc, files_str)

		callback(nil, spec)
	end)
end

perforce.save_change_spec = function(spec, callback)
	vim.schedule(function()
		callback(nil, "Change specification saved successfully")
	end)
end

-- Initialize crude and perforce crude plugin
crude.setup()
p4_crude.setup()

-- Set up window layout if no arguments passed
if vim.fn.argc() == 0 then
	vim.cmd("edit p4://default")
	vim.cmd("vsplit p4://10492")
	vim.cmd("wincmd h")

	local banner = [[
[perforce.nvim + crude.nvim] Interactive Demo Ready!

Left window:  p4://default
Right window: p4://10492

Features & Instructions:
• Full Depot Paths: Entries are genuine Perforce depot paths (//depot/...) without virtual text hacks!
• Action column: Displays 'edit', 'add', 'delete' with syntax highlights (DiffChange, DiffAdd, DiffDelete).
• Cross-buffer Move:
  1. In left window (p4://default), cut a line with `dd`.
  2. Switch to right window (`<C-w>w`).
  3. Paste with `p`.
  4. Type `:w` (saves both buffers and executes `p4 reopen -c 10492 <file>`).
• Rename Depot Path: Edit a line directly and `:w` (executes `p4 move`).
• Revert: Delete a line with `dd` and `:w` (executes `p4 revert`).
• Navigation:
  - Press `-` to navigate up to changelist overview (`p4://opened`).
  - Press `<CR>` on a changelist in the overview to open its files.
• Change Specification Editor:
  - Run `:P4 change 10492` or `:P4 change default` to open floating change spec editor (`p4 change -o / -i`).
]]
	vim.notify(banner, vim.log.levels.INFO)
end
