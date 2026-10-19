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

-- Submitted history (read-only in p4://history and p4://<cl>)
local mock_submitted = {
	["10400"] = {
		desc = "Fix crash on shutdown",
		user = "teammate",
		files = { { depotFile = "//depot/core/src/main.cpp", action = "edit", rev = "7" } },
	},
	["10350"] = {
		desc = "Initial engine layout",
		user = "demo_developer",
		files = { { depotFile = "//depot/engine/README.md", action = "add", rev = "1" } },
	},
}

-- Real directory acting as the workspace root so `-`, <CR> and crude-fs signs work
local root = vim.fs.normalize(vim.fn.stdpath("cache") .. "/perforce-nvim-demo")
local is_windows = vim.fn.has("win32") == 1

---//depot/foo/bar -> <root>/foo/bar
local function depot_to_local(depot)
	return root .. "/" .. depot:gsub("^//depot/", "")
end

---<root>/foo/bar (any slashes/case) -> //depot/foo/bar
local function local_to_depot(path)
	local p = vim.fs.normalize(path)
	local prefix = root .. "/"
	local cmp_p, cmp_prefix = p, prefix
	if is_windows then
		cmp_p, cmp_prefix = p:lower(), prefix:lower()
	end
	if cmp_p:sub(1, #cmp_prefix) ~= cmp_prefix then
		return nil
	end
	return "//depot/" .. p:sub(#prefix + 1)
end

local function native(path)
	return is_windows and path:gsub("/", "\\") or path
end

local function to_depot(name)
	if name:match("^//") then
		return name
	end
	return local_to_depot(name) or name
end

---Find an opened record by depot path
local function find_opened(depot)
	for cl, list in pairs(mock_store) do
		for i, item in ipairs(list) do
			if item.depotFile == depot then
				return item, cl, i
			end
		end
	end
end

local function remove_opened(depot)
	local _, cl, i = find_opened(depot)
	if cl then
		table.remove(mock_store[cl], i)
	end
end

local function open_file(depot, cl, action)
	remove_opened(depot)
	mock_store[cl] = mock_store[cl] or {}
	table.insert(mock_store[cl], { depotFile = depot, action = action, change = cl, type = "text", rev = "1" })
end

-- Populate the demo workspace on disk
for _, list in pairs(mock_store) do
	for _, item in ipairs(list) do
		if item.action ~= "delete" then
			local path = depot_to_local(item.depotFile)
			vim.fn.mkdir(vim.fs.dirname(path), "p")
			if vim.fn.filereadable(path) == 0 then
				vim.fn.writefile({ "// " .. item.depotFile }, path)
			end
		end
	end
end
for _, extra in ipairs({ "core/src/main.cpp", "engine/README.md", "tools/build.py" }) do
	local path = root .. "/" .. extra
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	if vim.fn.filereadable(path) == 0 then
		vim.fn.writefile({ "# " .. extra }, path)
	end
end

local function later(callback, ...)
	local args = { ... }
	vim.schedule(function()
		callback(unpack(args, 1, 2))
	end)
end

-- Mock Perforce API functions for seamless standalone demo
perforce.info = function(callback)
	later(callback, nil, {
		clientName = "demo_client",
		userName = "demo_developer",
		clientRoot = root,
	})
end

perforce.get_workspace_root = function(path, callback)
	callback(local_to_depot(path .. "/x") and root or nil)
end

perforce.opened = function(opts, callback)
	opts = opts or {}
	local out = {}
	for cl, files in pairs(mock_store) do
		if not opts.changelist or tostring(opts.changelist) == cl then
			vim.list_extend(out, files)
		end
	end
	later(callback, nil, out)
end

perforce.changes = function(opts, callback)
	local list = {}
	for cl, desc in pairs(mock_descriptions) do
		if cl ~= "default" then
			table.insert(list, { change = cl, user = "demo_developer", client = "demo_client", status = "pending", desc = desc })
		end
	end
	if opts.status ~= "pending" then
		for cl, ch in pairs(mock_submitted) do
			table.insert(list, { change = cl, user = ch.user, client = "other_client", status = "submitted", desc = ch.desc })
		end
	end
	later(callback, nil, list)
end

perforce.describe = function(cl, callback)
	local ch = mock_submitted[tostring(cl)]
	if ch then
		later(callback, nil, { change = cl, status = "submitted", client = "other_client", user = ch.user, desc = ch.desc, files = ch.files })
	elseif mock_descriptions[tostring(cl)] then
		later(callback, nil, { change = cl, status = "pending", client = "demo_client", desc = mock_descriptions[tostring(cl)], files = {} })
	else
		later(callback, { { data = "Change " .. tostring(cl) .. " unknown.", severity = 3 } }, nil)
	end
end

perforce.where = function(files, callback)
	local out = {}
	for _, f in ipairs(files) do
		local depot = to_depot(f)
		table.insert(out, { depotFile = depot, path = native(depot_to_local(depot)) })
	end
	later(callback, nil, out)
end

perforce.fstat = function(opts, callback)
	local out = {}
	if opts.opened_only then
		for _, list in pairs(mock_store) do
			for _, item in ipairs(list) do
				table.insert(out, { clientFile = native(depot_to_local(item.depotFile)), action = item.action, change = item.change })
			end
		end
	else
		for _, f in ipairs(opts.files or {}) do
			local depot = to_depot(f)
			local item = find_opened(depot)
			local path = depot_to_local(depot)
			table.insert(out, {
				depotFile = depot,
				clientFile = native(path),
				headRev = (item or vim.fn.filereadable(path) == 1) and "1" or nil,
				headAction = "edit",
				action = item and item.action or nil,
				change = item and item.change or nil,
			})
		end
	end
	later(callback, nil, out)
end

perforce.reopen = function(opts, callback)
	local target_cl = tostring(opts.changelist)
	for _, file in ipairs(opts.files) do
		local depot = to_depot(file)
		local item = find_opened(depot)
		open_file(depot, target_cl, item and item.action or "edit")
	end
	later(callback, nil, { { action = "reopened" } })
end

perforce.edit = function(opts, callback)
	for _, file in ipairs(opts.files) do
		open_file(to_depot(file), tostring(opts.changelist or "default"), "edit")
	end
	later(callback, nil, { { action = "edit" } })
end

perforce.add = function(opts, callback)
	for _, file in ipairs(opts.files) do
		open_file(to_depot(file), tostring(opts.changelist or "default"), "add")
	end
	later(callback, nil, { { action = "add" } })
end

perforce.move = function(opts, callback)
	local item = find_opened(to_depot(opts.from_file))
	if item then
		item.depotFile = to_depot(opts.to_file)
		item.action = "move/add"
	end
	later(callback, nil, { { action = "moved" } })
end

perforce.revert = function(opts, callback)
	for _, f in ipairs(opts.files) do
		remove_opened(to_depot(f))
	end
	later(callback, nil, { { action = "reverted" } })
end

perforce.print = function(opts, callback)
	later(callback, nil, "-- mock depot content of " .. opts.file .. "\n")
end

perforce.change_spec = function(cl, callback)
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

	later(callback, nil, spec)
end

perforce.save_change_spec = function(spec, callback)
	later(callback, nil, "Change specification saved successfully")
end

-- Initialize crude, then register the perforce provider and crude-fs signs extension manually
crude.setup()
crude.register_provider("crude-fs", crude.providers["crude-fs"])
crude.register_provider("perforce", p4_crude.provider)
crude.register_extension("crude-fs-p4", p4_crude.fs_signs)

vim.keymap.set("n", "<leader>pc", function()
	local entry = p4_crude.cursor_entry()
	p4_crude.open_change(entry and entry.meta and entry.meta.changelist or "default")
end, { desc = "Edit Perforce change spec" })

-- Set up window layout if no arguments passed
if vim.fn.argc() == 0 then
	vim.cmd("edit p4://default")
	vim.cmd("vsplit p4://10492")
	vim.cmd("wincmd h")

	local banner = [[
[perforce.nvim + crude.nvim] Interactive Demo Ready!

Left window:  p4://default
Right window: p4://10492
Mock workspace root: ]] .. root .. [[


Features & Instructions:
• Full Depot Paths: Entries are genuine Perforce depot paths (//depot/...).
• Cross-buffer Move: `dd` a line in one changelist, `p` it in the other, `:w` (p4 reopen).
• Rename: Edit a depot path and `:w` (p4 move).
• Add/Edit: Type a depot or local path on a new line and `:w` (p4 reopen / edit / add).
• Revert: `dd` a line and `:w` (p4 revert -k, workspace file kept).
• Navigation:
  - `-` in a changelist goes back to the overview it came from (p4:// by default).
  - `-` in p4:// opens the workspace root in crude-fs, with signs for opened files.
  - `<CR>` on a changelist opens it; on a file opens the local file.
  - Also try p4://opened and p4://history (read-only, with submitted changelists).
• Change spec: `<leader>pc` on a line (or :lua require("perforce.plugins.crude").open_change("10492")).
]]
	vim.notify(banner, vim.log.levels.INFO)
end
