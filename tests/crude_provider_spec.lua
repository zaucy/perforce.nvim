local helper = require("test_helper")
local assert = helper.assert
local provider = require("perforce.plugins.crude.provider")
local perforce = require("perforce")
local crude = require("crude")
local p4_crude = require("perforce.plugins.crude")
local cache = require("crude.cache")

---Helper to create or reset a named buffer cleanly
---@param name string
---@return integer bufnr
local function make_buf(name)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
			pcall(vim.api.nvim_buf_delete, b, { force = true })
		end
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, name)
	return buf
end

describe("Perforce Crude Provider", function()
	describe("URL Parsing", function()
		it("parses empty or root URLs as opened overview", function()
			local r1 = provider.parse_url("p4://")
			assert.are_equal("overview", r1.type)
			assert.are_equal("opened", r1.mode)
			assert.is_nil(r1.changelist)

			local r2 = provider.parse_url("perforce://")
			assert.are_equal("overview", r2.type)
			assert.are_equal("opened", r2.mode)
		end)

		it("parses opened, history, changes, and pending overview URLs", function()
			local r_opened = provider.parse_url("p4://opened")
			assert.are_equal("overview", r_opened.type)
			assert.are_equal("opened", r_opened.mode)

			local r_history = provider.parse_url("p4://history")
			assert.are_equal("overview", r_history.type)
			assert.are_equal("history", r_history.mode)

			local r_pending = provider.parse_url("p4://pending")
			assert.are_equal("overview", r_pending.type)
			assert.are_equal("pending", r_pending.mode)

			local r_changes = provider.parse_url("p4://changes")
			assert.are_equal("overview", r_changes.type)
			assert.are_equal("pending", r_changes.mode)
		end)

		it("parses changelist URLs (numeric or default)", function()
			local r_num = provider.parse_url("p4://12345")
			assert.are_equal("changelist", r_num.type)
			assert.are_equal("changelist", r_num.mode)
			assert.are_equal("12345", r_num.changelist)

			local r_def = provider.parse_url("p4://default")
			assert.are_equal("changelist", r_def.type)
			assert.are_equal("changelist", r_def.mode)
			assert.are_equal("default", r_def.changelist)

			local r_sub = provider.parse_url("p4://opened/54321")
			assert.are_equal("changelist", r_sub.type)
			assert.are_equal("opened", r_sub.mode)
			assert.are_equal("54321", r_sub.changelist)
		end)
	end)

	describe("Entry Name Validation", function()
		it("accepts valid depot paths and file paths in changelist buffers", function()
			local buf = make_buf("p4://val_test_1")

			local ok1 = provider.validate_entry_name("//depot/project/main.cpp", buf)
			assert.is_true(ok1)

			local ok2 = provider.validate_entry_name("C:/project/main.cpp", buf)
			assert.is_true(ok2)

			local ok3 = provider.validate_entry_name("/unix/project/main.cpp", buf)
			assert.is_true(ok3)

			local ok4 = provider.validate_entry_name("./relative/main.cpp", buf)
			assert.is_true(ok4)
		end)

		it("rejects invalid relative non-path entry names in changelist buffers", function()
			local buf = make_buf("p4://val_test_2")

			local ok, err = provider.validate_entry_name("invalid_name_without_slash", buf)
			assert.is_false(ok)
			assert.truthy(err)
			assert.matches("must be a valid Perforce depot path", err)
		end)
	end)

	describe("Columns", function()
		it("provides read-only action column with highlights", function()
			assert.is_not_nil(provider.columns)
			assert.are_equal(1, #provider.columns)

			local col = provider.columns[1]
			assert.are_equal("action", col.name)
			assert.are_equal(false, col.editable)

			local text, hl = col.render({ columns = { action = "edit" } }, 0)
			assert.are_equal("edit", text)
			assert.are_equal("DiffChange", hl)

			local text_add, hl_add = col.render({ columns = { action = "add" } }, 0)
			assert.are_equal("add", text_add)
			assert.are_equal("DiffAdd", hl_add)

			local text_del, hl_del = col.render({ columns = { action = "delete" } }, 0)
			assert.are_equal("delete", text_del)
			assert.are_equal("DiffDelete", hl_del)

			local text_int, hl_int = col.render({ columns = { action = "integrate" } }, 0)
			assert.are_equal("integrate", text_int)
			assert.are_equal("Special", hl_int)
		end)
	end)

	describe("Listing Changelist Entries (Depot Paths)", function()
		local orig_opened = perforce.opened

		it("lists entries using FULL depot paths without virtual text hacks", function()
			perforce.opened = function(opts, callback)
				assert.are_equal("list_test_cl", opts.changelist)
				vim.schedule(function()
					callback(nil, {
						{
							depotFile = "//depot/engine/core/main.cpp",
							clientFile = "//my_client/engine/core/main.cpp",
							action = "edit",
							change = "list_test_cl",
							type = "text",
							rev = "4",
						},
						{
							depotFile = "//depot/engine/graphics/shader.hlsl",
							clientFile = "//my_client/engine/graphics/shader.hlsl",
							action = "add",
							change = "list_test_cl",
							type = "text",
							rev = "1",
						},
					})
				end)
			end

			local buf = make_buf("p4://list_test_cl")

			local entries = provider.list(buf)
			assert.are_equal(2, #entries)

			-- Entry names are full depot paths, NOT stripped basenames!
			assert.are_equal("//depot/engine/core/main.cpp", entries[1].name)
			assert.are_equal("//depot/engine/core/main.cpp", entries[1].id)
			assert.are_equal("edit", entries[1].columns.action)
			assert.are_equal("file", entries[1].meta.type)

			assert.are_equal("//depot/engine/graphics/shader.hlsl", entries[2].name)
			assert.are_equal("add", entries[2].columns.action)

			perforce.opened = orig_opened
		end)
	end)

	describe("Applying Diffs (Reopen, Move, Edit, Revert)", function()
		local orig_reopen = perforce.reopen
		local orig_move = perforce.move
		local orig_edit = perforce.edit
		local orig_revert = perforce.revert

		it("disallows modifying overview buffers", function()
			local buf = make_buf("p4://opened")

			assert.has_error(function()
				provider.apply(buf, { creates = {}, renames = {}, deletes = {} })
			end, "Overview buffers are read%-only")
		end)

		it("executes p4 reopen on cross-buffer moved entries", function()
			local reopened = {}
			perforce.reopen = function(opts, callback)
				reopened = opts
				vim.schedule(function()
					callback(nil, { { action = "reopened" } })
				end)
			end

			local buf = make_buf("p4://target_cl")

			local diffs = {
				creates = {
					{
						name = "//depot/pkg/moved_file.cpp",
						src_id = 99,
						src_bufnr = 1,
					},
				},
				renames = {},
				deletes = {},
			}

			provider.apply(buf, diffs)

			assert.are_equal("target_cl", reopened.changelist)
			assert.are_equal(1, #reopened.files)
			assert.are_equal("//depot/pkg/moved_file.cpp", reopened.files[1])

			perforce.reopen = orig_reopen
		end)

		it("executes p4 move on renames", function()
			local moved = {}
			perforce.move = function(opts, callback)
				moved = opts
				vim.schedule(function()
					callback(nil, { { action = "moved" } })
				end)
			end

			local buf = make_buf("p4://move_test_cl")

			local diffs = {
				creates = {},
				renames = {
					{
						id = "//depot/old.txt",
						from = "//depot/old.txt",
						to = "//depot/new.txt",
					},
				},
				deletes = {},
			}

			provider.apply(buf, diffs)

			assert.are_equal("move_test_cl", moved.changelist)
			assert.are_equal("//depot/old.txt", moved.from_file)
			assert.are_equal("//depot/new.txt", moved.to_file)

			perforce.move = orig_move
		end)

		it("executes p4 revert on deletions that are not moved to another buffer", function()
			local reverted = {}
			perforce.revert = function(opts, callback)
				reverted = opts
				vim.schedule(function()
					callback(nil, { { action = "reverted" } })
				end)
			end

			local buf = make_buf("p4://revert_test_cl")

			local diffs = {
				creates = {},
				renames = {},
				deletes = {
					{
						id = 42,
						name = "//depot/deleted.txt",
					},
				},
			}

			provider.apply(buf, diffs)

			assert.are_equal("revert_test_cl", reverted.changelist)
			assert.are_equal(1, #reverted.files)
			assert.are_equal("//depot/deleted.txt", reverted.files[1])

			perforce.revert = orig_revert
		end)
	end)

	describe("Navigation and Selection", function()
		it("navigates to parent overview on on_parent", function()
			local buf = make_buf("p4://nav_parent_test")
			vim.api.nvim_set_current_buf(buf)

			provider.on_parent(buf)
			local cur_buf = vim.api.nvim_get_current_buf()
			local cur_name = vim.api.nvim_buf_get_name(cur_buf)
			assert.are_equal("p4://opened", cur_name)
		end)

		it("selects overview entry and opens changelist buffer", function()
			local buf = make_buf("p4://opened")
			vim.api.nvim_set_current_buf(buf)

			provider.on_select({ name = "select_test_cl/" }, buf)
			local cur_buf = vim.api.nvim_get_current_buf()
			local cur_name = vim.api.nvim_buf_get_name(cur_buf)
			assert.are_equal("p4://select_test_cl", cur_name)
		end)
	end)

	describe("Full Integration with crude.nvim", function()
		local orig_opened = perforce.opened
		local orig_reopen = perforce.reopen

		it("loads and renders changelists in crude buffers with depot paths", function()
			cache.reset()
			p4_crude.setup()

			perforce.opened = function(opts, callback)
				vim.schedule(function()
					if opts.changelist == "integ_a" then
						callback(nil, {
							{ depotFile = "//depot/repo/alpha.lua", action = "edit", change = "integ_a" },
							{ depotFile = "//depot/repo/beta.lua", action = "edit", change = "integ_a" },
						})
					else
						callback(nil, {})
					end
				end)
			end

			local buf_a = make_buf("p4://integ_a")
			vim.api.nvim_set_current_buf(buf_a)

			-- Load buffer via crude
			vim.async.await(crude.load_buffer(buf_a))

			assert.are_equal("acwrite", vim.bo[buf_a].buftype)
			assert.are_equal("crude", vim.bo[buf_a].filetype)

			local lines = vim.api.nvim_buf_get_lines(buf_a, 0, -1, false)
			assert.are_equal(2, #lines)
			-- Verify the lines contain the proper depot paths and action column
			assert.truthy(lines[1]:match("//depot/repo/alpha%.lua"))
			assert.truthy(lines[2]:match("//depot/repo/beta%.lua"))
			assert.truthy(lines[1]:match("edit"))

			perforce.opened = orig_opened
		end)

		it("supports moving a depot path between changelist buffers and saving", function()
			cache.reset()
			p4_crude.setup()

			local reopened_calls = {}
			perforce.reopen = function(opts, callback)
				table.insert(reopened_calls, opts)
				vim.schedule(function()
					callback(nil, { { action = "reopened" } })
				end)
			end

			perforce.opened = function(opts, callback)
				vim.schedule(function()
					if opts.changelist == "move_src" then
						callback(nil, {
							{ depotFile = "//depot/repo/file_to_move.lua", action = "edit", change = "move_src" },
						})
					elseif opts.changelist == "move_dst" then
						callback(nil, {})
					end
				end)
			end

			local buf_src = make_buf("p4://move_src")
			local buf_dst = make_buf("p4://move_dst")

			vim.async.await(crude.load_buffer(buf_src))
			vim.async.await(crude.load_buffer(buf_dst))

			local src_lines = vim.api.nvim_buf_get_lines(buf_src, 0, -1, false)
			assert.are_equal(1, #src_lines)
			local moved_line = src_lines[1]

			-- Simulate cut & paste: remove line from buf_src, add to buf_dst
			vim.api.nvim_buf_set_lines(buf_src, 0, -1, false, {})
			vim.bo[buf_src].modified = true

			vim.api.nvim_buf_set_lines(buf_dst, 0, -1, false, { moved_line })
			vim.bo[buf_dst].modified = true

			-- Save destination buffer (which triggers multi-buffer save of involved crude buffers)
			vim.async.await(crude.save_buffer(buf_dst))

			assert.are_equal(1, #reopened_calls)
			assert.are_equal("move_dst", reopened_calls[1].changelist)
			assert.are_equal(1, #reopened_calls[1].files)
			assert.are_equal("//depot/repo/file_to_move.lua", reopened_calls[1].files[1])

			perforce.opened = orig_opened
			perforce.reopen = orig_reopen
		end)
	end)
end)
