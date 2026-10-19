local helper = require("test_helper")
local assert = helper.assert
local perforce = require("perforce")
local crude = require("crude")
local cache = require("crude.cache")
local crude_provider = require("crude.provider")
local p4_crude = require("perforce.plugins.crude")
local p4 = require("perforce.plugins.crude.p4")
local url = require("perforce.plugins.crude.url")
local provider = require("perforce.plugins.crude.provider")

-- Register the default instance once so p4://* autocmds exist for :edit based navigation
crude.register_provider("perforce", p4_crude.provider)

---Replace perforce.* functions for the duration of fn, restoring them afterwards (even on error)
---@param mocks table<string, function>
---@param fn fun()
local function with_mocks(mocks, fn)
	local orig = {}
	for k, v in pairs(mocks) do
		orig[k] = perforce[k]
		perforce[k] = v
	end
	p4.reset()
	local ok, err = pcall(fn)
	for k, v in pairs(orig) do
		perforce[k] = v
	end
	p4.reset()
	if not ok then
		error(err, 0)
	end
end

---Callback-style mock that answers asynchronously like the real perforce API
---@param result any
---@param errors? any
---@param calls? table collects the options of each call
local function respond(result, errors, calls)
	return function(opts, cb)
		if calls then
			table.insert(calls, opts)
		end
		vim.schedule(function()
			cb(errors, type(result) == "function" and result(opts) or result)
		end)
	end
end

local function info_mock(root)
	return function(cb)
		vim.schedule(function()
			cb(nil, { clientName = "test_client", userName = "tester", clientRoot = root or "C:/ws" })
		end)
	end
end

---@param name string
---@return integer
local function make_buf(name)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
			pcall(vim.api.nvim_buf_delete, b, { force = true })
		end
	end
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, name)
	return buf
end

---@param buf integer
---@param prov? crude.Provider
local function load(buf, prov)
	vim.async.await(crude.load_buffer(buf, prov or p4_crude.provider, "perforce"))
end

---Entry lines (without the 2 header lines and the blank placeholder of empty buffers)
---@param buf integer
---@return string[]
local function entry_lines(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	return vim.tbl_filter(function(line)
		return not line:match("^%s*$")
	end, vim.list_slice(lines, 3))
end

---@param cond fun(): boolean
---@param timeout? integer
local function wait_until(cond, timeout)
	local deadline = vim.uv.now() + (timeout or 2000)
	while not cond() do
		if vim.uv.now() > deadline then
			error("timed out waiting for condition", 2)
		end
		vim.async.sleep(10)
	end
end

---Fresh diff result
local function diffs(t)
	return vim.tbl_extend("force", { creates = {}, renames = {}, deletes = {}, column_changes = {}, copies = {}, errors = {}, clean = false }, t or {})
end

local function opened_by_cl(store)
	return function(opts)
		if opts.changelist then
			return store[opts.changelist] or {}
		end
		local all = {}
		for _, files in pairs(store) do
			vim.list_extend(all, files)
		end
		return all
	end
end

describe("perforce crude provider", function()
	describe("url", function()
		it("parses overview URLs", function()
			assert.are_equal("pending", url.parse("p4://").kind)
			assert.are_equal("pending", url.parse("p4://pending").kind)
			assert.are_equal("opened", url.parse("p4://opened").kind)
			assert.are_equal("history", url.parse("p4://history/").kind)
		end)

		it("parses changelist URLs", function()
			assert.same({ kind = "changelist", changelist = "12345" }, url.parse("p4://12345"))
			assert.same({ kind = "changelist", changelist = "default" }, url.parse("p4://default"))
		end)

		it("rejects malformed URLs", function()
			assert.has_error(function()
				url.parse("p4://not-a-cl")
			end, "Invalid changelist")
			assert.has_error(function()
				url.parse("oil-p4://123")
			end, "Not a p4://")
			assert.is_nil(url.try_parse("crude-fs:///tmp"))
		end)

		it("round-trips through format", function()
			for _, name in ipairs({ "p4://", "p4://opened", "p4://history", "p4://default", "p4://42" }) do
				assert.are_equal(name, url.format(url.parse(name)))
			end
		end)
	end)

	describe("options", function()
		it("validates delete_action and history_max", function()
			assert.has_error(function()
				p4_crude.provider({ delete_action = "nuke" })
			end, "delete_action")
			assert.has_error(function()
				p4_crude.provider({ history_max = 0 })
			end, "history_max")
			local prov = p4_crude.provider({ delete_action = "revert", history_max = 10 })
			assert.are_equal("revert", prov.options.delete_action)
			assert.is_true(prov._perforce)
		end)
	end)

	describe("p4 helpers", function()
		it("treats -Mj warnings as errors for mutations but not for queries", function()
			local warn = { { data = "x - file(s) not in client view.\n", severity = 2, generic = 17 } }
			assert.are_equal("x - file(s) not in client view.", p4.error_message(nil, warn))
			assert.is_nil(p4.error_message(nil, warn, 3))
			assert.is_nil(p4.error_message(nil, { { depotFile = "//a" } }))
			assert.are_equal("p4 exited with code 1", p4.error_message({ "p4 exited with code 1" }, {}))
			assert.same({ { depotFile = "//a" } }, p4.records({ { depotFile = "//a" }, warn[1] }))
		end)
	end)

	describe("columns", function()
		it("provides per-kind column sets", function()
			local function names(name)
				local buf = make_buf(name)
				local out = {}
				for _, c in ipairs(provider.columns(buf)) do
					table.insert(out, c.name)
				end
				return table.concat(out, ",")
			end
			assert.are_equal("user,files,name,description", names("p4://"))
			assert.are_equal("user,files,name,description", names("p4://opened"))
			assert.are_equal("user,status,name,description", names("p4://history"))
			assert.are_equal("action,name", names("p4://77"))
		end)

		it("highlights actions", function()
			local col = provider.column_sets.changelist[1]
			local text, hl = col.render({ columns = { action = "move/add" } }, 0)
			assert.are_equal("move/add", text)
			assert.are_equal("PerforceCrudeActionMove", hl)
		end)

		it("sorts default first, then newest", function()
			local cls = { "100", "default", "2000", "300" }
			table.sort(cls, provider.changelist_lt)
			assert.same({ "default", "2000", "300", "100" }, cls)
		end)
	end)

	describe("listing", function()
		it("lists pending changelists with user, file counts, and descriptions", function()
			with_mocks({
				info = info_mock(),
				opened = respond(opened_by_cl({
					default = { { depotFile = "//d/a", change = "default", action = "edit" } },
					["200"] = { { depotFile = "//d/b", change = "200", action = "add" }, { depotFile = "//d/c", change = "200", action = "edit" } },
				})),
				changes = respond({
					{ change = "100", user = "tester", status = "pending", desc = "\nOlder work\nsecond line" },
					{ change = "200", user = "tester", status = "pending", desc = "Newer work" },
				}),
			}, function()
				cache.reset()
				local buf = make_buf("p4://")
				load(buf)
				local lines = entry_lines(buf)
				assert.are_equal(3, #lines)
				assert.matches("tester%s+1 default%s+Default changelist$", lines[1])
				assert.matches("tester%s+2 200%s+Newer work$", lines[2])
				assert.matches("tester%s+100%s+Older work$", lines[3])
				assert.is_true(provider.is_readonly(buf))
			end)
		end)

		it("only lists changelists with opened files in p4://opened", function()
			with_mocks({
				info = info_mock(),
				opened = respond(opened_by_cl({ ["200"] = { { depotFile = "//d/b", change = "200", action = "add" } } })),
				changes = respond({
					{ change = "100", user = "tester", status = "pending", desc = "Empty" },
					{ change = "200", user = "tester", status = "pending", desc = "Has files" },
				}),
			}, function()
				cache.reset()
				local buf = make_buf("p4://opened")
				load(buf)
				local lines = entry_lines(buf)
				assert.are_equal(1, #lines)
				assert.matches("200%s+Has files$", lines[1])
			end)
		end)

		it("lists server history with status", function()
			local calls = {}
			with_mocks({
				info = info_mock(),
				changes = respond({
					{ change = "9", user = "alice", status = "submitted", desc = "Fix crash" },
					{ change = "10", user = "bob", status = "pending", desc = "WIP" },
				}, nil, calls),
			}, function()
				cache.reset()
				local buf = make_buf("p4://history")
				load(buf, p4_crude.provider({ history_max = 7 }))
				assert.are_equal(7, calls[1].max)
				local lines = entry_lines(buf)
				assert.matches("bob%s+pending%s+10%s+WIP$", lines[1])
				assert.matches("alice%s+submitted%s+9%s+Fix crash$", lines[2])
			end)
		end)

		it("lists opened files of a changelist using full depot paths", function()
			with_mocks({
				info = info_mock(),
				opened = respond(opened_by_cl({
					["55"] = {
						{ depotFile = "//depot/repo/alpha.lua", action = "edit", change = "55", rev = "3" },
						{ depotFile = "//depot/repo/beta.lua", action = "add", change = "55" },
					},
				})),
			}, function()
				cache.reset()
				local buf = make_buf("p4://55")
				load(buf)
				assert.are_equal("acwrite", vim.bo[buf].buftype)
				assert.are_equal("crude", vim.bo[buf].filetype)
				local header = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
				assert.matches("ACTION%s+FILE", header)
				local lines = entry_lines(buf)
				assert.are_equal(2, #lines)
				assert.matches("edit%s+//depot/repo/alpha%.lua$", lines[1])
				assert.matches("add%s+//depot/repo/beta%.lua$", lines[2])
				assert.is_false(provider.is_readonly(buf))
			end)
		end)

		it("falls back to describe and marks submitted changelists read-only", function()
			with_mocks({
				info = info_mock(),
				opened = respond({ { data = "File(s) not opened on this client.\n", severity = 2 } }),
				describe = function(cl, cb)
					vim.schedule(function()
						cb(nil, {
							change = cl,
							status = "submitted",
							client = "someone",
							files = { { depotFile = "//depot/old.txt", action = "delete", rev = "4" } },
						})
					end)
				end,
			}, function()
				cache.reset()
				local buf = make_buf("p4://88")
				load(buf)
				local lines = entry_lines(buf)
				assert.are_equal(1, #lines)
				assert.matches("delete%s+//depot/old%.txt$", lines[1])
				assert.is_true(provider.is_readonly(buf))
			end)
		end)
	end)

	describe("validation", function()
		it("accepts depot and local paths, rejects wildcards and revisions", function()
			local buf = make_buf("p4://31")
			local v = p4_crude.provider.validate_entry_name
			assert.is_true(v("//depot/project/main.cpp", buf))
			assert.is_true(v("C:/project/main.cpp", buf))
			assert.is_true(v("/unix/project/main.cpp", buf))
			assert.is_true(v("./relative/main.cpp", buf))
			local ok, err = v("main.cpp", buf)
			assert.is_false(ok)
			assert.matches("depot path", err)
			ok, err = v("//depot/...", buf)
			assert.is_false(ok)
			assert.matches("Wildcards", err)
			ok, err = v("//depot/a.txt#3", buf)
			assert.is_false(ok)
			assert.matches("Revision", err)
		end)
	end)

	describe("apply", function()
		local function ctx_for(buf, d)
			return crude_provider.create_context(buf, d)
		end

		it("reports read-only errors in overview and submitted buffers", function()
			local over = make_buf("p4://opened")
			local d = diffs({ deletes = { { id = "opened:1", name = "1" } } })
			local ctx = ctx_for(over, d)
			p4_crude.provider.apply(over, d, ctx)
			assert.are_equal(1, #ctx:get_errors())
			assert.matches("read%-only", ctx:get_errors()[1].message)

			local sub = make_buf("p4://99")
			vim.b[sub].perforce_crude_readonly = true
			local d2 = diffs({ renames = { { id = "99://a", from = "//a", to = "//b" } } })
			local ctx2 = ctx_for(sub, d2)
			p4_crude.provider.apply(sub, d2, ctx2)
			assert.matches("Changelist 99 is read%-only", ctx2:get_errors()[1].message)
		end)

		it("reverts deleted files keeping workspace files by default", function()
			local calls = {}
			local fired = 0
			local au = vim.api.nvim_create_autocmd("User", {
				pattern = "PerforceOpenedChanged",
				callback = function()
					fired = fired + 1
				end,
			})
			with_mocks({ revert = respond({ { depotFile = "//d/a", action = "reverted" } }, nil, calls) }, function()
				local buf = make_buf("p4://12")
				vim.b[buf].perforce_crude_readonly = false
				local del = { id = "12://d/a", name = "//d/a", entry = { meta = { depot_file = "//d/a" } } }
				local d = diffs({ deletes = { del } })
				local ctx = ctx_for(buf, d)
				p4_crude.provider.apply(buf, d, ctx)
				assert.are_equal(0, #ctx:get_errors())
				assert.are_equal(1, #calls)
				assert.are_equal("12", calls[1].changelist)
				assert.same({ "//d/a" }, calls[1].files)
				assert.is_true(calls[1].keep_workspace_files)
				assert.is_true(ctx:is_done(del))
			end)
			vim.api.nvim_del_autocmd(au)
			assert.are_equal(1, fired)
		end)

		it("honors delete_action = 'revert' and 'disabled'", function()
			local calls = {}
			with_mocks({ revert = respond({}, nil, calls) }, function()
				local buf = make_buf("p4://13")
				vim.b[buf].perforce_crude_readonly = false

				local d = diffs({ deletes = { { id = "13://d/a", name = "//d/a" } } })
				p4_crude.provider({ delete_action = "revert" }).apply(buf, d, ctx_for(buf, d))
				assert.are_equal(1, #calls)
				assert.is_false(calls[1].keep_workspace_files)

				local d2 = diffs({ deletes = { { id = "13://d/a", name = "//d/a" } } })
				local ctx2 = ctx_for(buf, d2)
				p4_crude.provider({ delete_action = "disabled" }).apply(buf, d2, ctx2)
				assert.are_equal(1, #calls)
				assert.matches("disabled", ctx2:get_errors()[1].message)
			end)
		end)

		it("surfaces p4 warnings as per-item errors", function()
			with_mocks({
				revert = respond({ { data = "//d/a - file(s) not opened on this client.\n", severity = 2 } }),
			}, function()
				local buf = make_buf("p4://14")
				vim.b[buf].perforce_crude_readonly = false
				local del = { id = "14://d/a", name = "//d/a" }
				local d = diffs({ deletes = { del } })
				local ctx = ctx_for(buf, d)
				p4_crude.provider.apply(buf, d, ctx)
				assert.are_equal(1, #ctx:get_errors())
				assert.are_equal(del, ctx:get_errors()[1].item)
				assert.matches("not opened", ctx:get_errors()[1].message)
			end)
		end)

		it("runs p4 move on renames", function()
			local calls = {}
			with_mocks({ move = respond({ { action = "moved" } }, nil, calls) }, function()
				local buf = make_buf("p4://15")
				vim.b[buf].perforce_crude_readonly = false
				local d = diffs({
					renames = { { id = "15://d/old", from = "//d/old", to = "//d/new", entry = { meta = { depot_file = "//d/old" } } } },
				})
				local ctx = ctx_for(buf, d)
				p4_crude.provider.apply(buf, d, ctx)
				assert.are_equal(0, #ctx:get_errors())
				assert.same({ changelist = "15", from_file = "//d/old", to_file = "//d/new" }, calls[1])
			end)
		end)

		it("opens typed paths with edit, add, or reopen depending on fstat", function()
			local edit_calls, add_calls, reopen_calls = {}, {}, {}
			with_mocks({
				fstat = respond(function(opts)
					local f = opts.files[1]
					if f == "//d/exists" then
						return { { depotFile = f, headRev = "3", headAction = "edit" } }
					elseif f == "//d/opened_elsewhere" then
						return { { depotFile = f, headRev = "1", action = "edit", change = "default" } }
					elseif f == "//d/deleted_at_head" then
						return { { depotFile = f, headRev = "4", headAction = "delete", clientFile = "C:/ws/deleted_at_head" } }
					end
					return { { data = f .. " - no such file(s).\n", severity = 2 } }
				end),
				edit = respond({ { action = "edit" } }, nil, edit_calls),
				add = respond({ { action = "add" } }, nil, add_calls),
				reopen = respond({ { action = "reopened" } }, nil, reopen_calls),
			}, function()
				local buf = make_buf("p4://16")
				vim.b[buf].perforce_crude_readonly = false
				local d = diffs({
					creates = {
						{ name = "//d/exists", lnum = 3 },
						{ name = "//d/opened_elsewhere", lnum = 4 },
						{ name = "//d/deleted_at_head", lnum = 5 },
						{ name = "C:/ws/brand_new.txt", lnum = 6 },
					},
				})
				local ctx = ctx_for(buf, d)
				p4_crude.provider.apply(buf, d, ctx)
				assert.are_equal(0, #ctx:get_errors())
				assert.same({ changelist = "16", files = { "//d/exists" } }, edit_calls[1])
				assert.same({ changelist = "16", files = { "//d/opened_elsewhere" } }, reopen_calls[1])
				assert.are_equal(2, #add_calls)
				assert.same({ "C:/ws/deleted_at_head" }, add_calls[1].files)
				assert.same({ "C:/ws/brand_new.txt" }, add_calls[2].files)
			end)
		end)

		it("rejects copies and moves from non-perforce buffers", function()
			local buf = make_buf("p4://17")
			vim.b[buf].perforce_crude_readonly = false
			local other = make_buf("C:/some/dir")
			local d = diffs({
				creates = {
					{ name = "//d/copied", lnum = 3, is_copy = true, src_id = "18://d/copied", src_bufnr = buf },
					{ name = "//d/from_fs", lnum = 4, is_move = true, src_id = 7, src_bufnr = other },
				},
			})
			local ctx = ctx_for(buf, d)
			p4_crude.provider.apply(buf, d, ctx)
			local errs = ctx:get_errors()
			assert.are_equal(2, #errs)
			assert.matches("only be open in one changelist", errs[1].message)
			assert.matches("Only entries cut from other p4://", errs[2].message)
		end)

		it("refuses to move perforce entries into non-perforce buffers", function()
			local buf = make_buf("p4://19")
			vim.b[buf].perforce_crude_readonly = false
			local other = make_buf("C:/another/dir")
			local del = { id = "19://d/x", name = "//d/x", is_move = true, dest_bufnr = other }
			local d = diffs({ deletes = { del } })
			local ctx = ctx_for(buf, d)
			p4_crude.provider.apply(buf, d, ctx)
			assert.matches("can only be moved into other p4://", ctx:get_errors()[1].message)
		end)
	end)

	describe("navigation", function()
		it("opens a changelist from an overview and returns to it with -", function()
			local prov = p4_crude.provider
			local over = make_buf("p4://opened")
			vim.api.nvim_set_current_buf(over)
			prov.on_select({ name = "4242", meta = { changelist = "4242" } }, over)
			assert.are_equal("p4://opened", prov._parent_by_cl["4242"])

			local cl_buf = make_buf("p4://4242")
			with_mocks({
				info = info_mock(),
				opened = respond({}),
				changes = respond({}),
				describe = function(_, cb)
					vim.schedule(function()
						cb(nil, { status = "pending", client = "test_client", files = {} })
					end)
				end,
			}, function()
				vim.api.nvim_set_current_buf(cl_buf)
				prov.on_parent(cl_buf)
				wait_until(function()
					return vim.api.nvim_buf_get_name(0) == "p4://opened"
				end)
			end)
		end)

		it("goes from p4://opened and p4://history to p4://", function()
			for _, name in ipairs({ "p4://opened", "p4://history" }) do
				with_mocks({ info = info_mock(), opened = respond({}), changes = respond({}) }, function()
					local buf = make_buf(name)
					vim.api.nvim_set_current_buf(buf)
					p4_crude.provider.on_parent(buf)
					wait_until(function()
						return vim.api.nvim_buf_get_name(0) == "p4://"
					end)
				end)
			end
		end)

		it("goes from p4:// to the workspace root directory", function()
			local root = vim.fs.normalize(vim.fn.tempname())
			vim.fn.mkdir(root, "p")
			with_mocks({ info = info_mock(root) }, function()
				local buf = make_buf("p4://")
				vim.api.nvim_set_current_buf(buf)
				p4_crude.provider.on_parent(buf)
				wait_until(function()
					return vim.fs.normalize(vim.api.nvim_buf_get_name(0)):gsub("/$", "") == root
				end)
			end)
			vim.fn.delete(root, "rf")
		end)
	end)

	describe("focus on open", function()
		local function wipe(name)
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
					pcall(vim.api.nvim_buf_delete, b, { force = true })
				end
			end
		end

		---:edit outside the async test coroutine (crude's BufReadCmd waits on the load)
		local function edit(name)
			local done = false
			vim.schedule(function()
				vim.cmd.edit(vim.fn.fnameescape(name))
				done = true
			end)
			wait_until(function()
				return done
			end)
		end

		local function cursor_line()
			return vim.api.nvim_get_current_line()
		end

		local function make_ws()
			local root = vim.fs.normalize(vim.fn.tempname())
			vim.fn.mkdir(root .. "/sub", "p")
			vim.fn.writefile({ "a" }, root .. "/sub/a.lua")
			vim.fn.writefile({ "b" }, root .. "/sub/b.lua")
			return root
		end

		---Wipe buffers of files under root before deleting it (otherwise E211 prompts block the run)
		local function remove_ws(root)
			local prefix = root:lower()
			for _, b in ipairs(vim.api.nvim_list_bufs()) do
				local name = vim.fs.normalize(vim.api.nvim_buf_get_name(b)):lower()
				if name:sub(1, #prefix) == prefix then
					pcall(vim.api.nvim_buf_delete, b, { force = true })
				end
			end
			vim.fn.delete(root, "rf")
		end

		local function pending_describe(cl, cb)
			vim.schedule(function()
				cb(nil, { change = cl, status = "pending", client = "test_client", files = {} })
			end)
		end

		it("focuses the current file in its changelist buffer", function()
			local root = make_ws()
			wipe("p4://801")
			with_mocks({
				info = info_mock(root),
				opened = respond(function(o)
					if o.changelist == "801" then
						return {
							{ depotFile = "//depot/sub/a.lua", clientFile = "//test_client/sub/a.lua", action = "edit", change = "801" },
							{ depotFile = "//depot/sub/b.lua", clientFile = "//TEST_CLIENT/sub/b.lua", action = "edit", change = "801" },
						}
					end
					return {}
				end),
				describe = pending_describe,
			}, function()
				edit(root .. "/sub/b.lua")
				edit("p4://801")
				wait_until(function()
					return cursor_line():find("//depot/sub/b.lua", 1, true) ~= nil
				end)
			end)
			remove_ws(root)
		end)

		it("focuses the changelist containing the current file in overviews", function()
			local root = make_ws()
			wipe("p4://")
			with_mocks({
				info = info_mock(root),
				opened = respond({
					{ depotFile = "//depot/sub/a.lua", clientFile = "//test_client/sub/a.lua", action = "edit", change = "802" },
				}),
				changes = respond({
					{ change = "803", user = "tester", desc = "newer" },
					{ change = "802", user = "tester", desc = "has a.lua" },
				}),
			}, function()
				edit(root .. "/sub/a.lua")
				edit("p4://")
				wait_until(function()
					return cursor_line():find("has a.lua", 1, true) ~= nil
				end)
			end)
			remove_ws(root)
		end)

		it("focuses the changelist you came from in overviews", function()
			wipe("p4://")
			wipe("p4://805")
			with_mocks({
				info = info_mock(),
				opened = respond({}),
				changes = respond({
					{ change = "806", user = "tester", desc = "other" },
					{ change = "805", user = "tester", desc = "came from here" },
				}),
				describe = pending_describe,
			}, function()
				edit("p4://805")
				wait_until(function()
					return vim.bo.filetype == "crude"
				end)
				edit("p4://")
				wait_until(function()
					return cursor_line():find("came from here", 1, true) ~= nil
				end)
			end)
		end)

		it("leaves the cursor alone for files that are not opened", function()
			local root = make_ws()
			wipe("p4://807")
			with_mocks({
				info = info_mock(root),
				opened = respond(function(o)
					if o.changelist == "807" then
						return {
							{ depotFile = "//depot/sub/a.lua", clientFile = "//test_client/sub/a.lua", action = "edit", change = "807" },
							{ depotFile = "//depot/sub/c.lua", clientFile = "//test_client/sub/c.lua", action = "edit", change = "807" },
						}
					end
					return {}
				end),
				describe = pending_describe,
			}, function()
				edit(root .. "/sub/b.lua")
				edit("p4://807")
				wait_until(function()
					return #vim.api.nvim_buf_get_lines(0, 0, -1, false) >= 4
				end)
				vim.async.sleep(50)
				assert.is_nil(cursor_line():find("c.lua", 1, true))
			end)
			remove_ws(root)
		end)
	end)

	describe("integration with crude.nvim", function()
		it("reopens a file cut from one changelist buffer and pasted into another", function()
			local reopen_calls, revert_calls = {}, {}
			with_mocks({
				info = info_mock(),
				opened = respond(function(opts)
					if opts.changelist == "501" then
						return { { depotFile = "//depot/repo/file_to_move.lua", action = "edit", change = "501" } }
					end
					return {}
				end),
				describe = function(cl, cb)
					vim.schedule(function()
						cb(nil, { change = cl, status = "pending", client = "test_client", files = {} })
					end)
				end,
				reopen = respond({ { action = "reopened" } }, nil, reopen_calls),
				revert = respond({}, nil, revert_calls),
			}, function()
				cache.reset()
				local src = make_buf("p4://501")
				local dst = make_buf("p4://502")
				load(src)
				load(dst)

				local src_lines = entry_lines(src)
				assert.are_equal(1, #src_lines)
				local moved = src_lines[1]

				vim.api.nvim_buf_set_lines(src, 2, 3, false, {})
				vim.bo[src].modified = true
				vim.api.nvim_buf_set_lines(dst, 2, -1, false, { moved })
				vim.bo[dst].modified = true

				vim.async.await(crude.save_buffer(dst))

				assert.are_equal(0, #revert_calls)
				assert.are_equal(1, #reopen_calls)
				assert.are_equal("502", reopen_calls[1].changelist)
				assert.same({ "//depot/repo/file_to_move.lua" }, reopen_calls[1].files)
			end)
		end)

		it("reverts (keeping workspace files) when a line is deleted and saved", function()
			local revert_calls = {}
			local reverted = false
			with_mocks({
				info = info_mock(),
				opened = respond(function(opts)
					if opts.changelist == "601" and not reverted then
						return { { depotFile = "//depot/repo/drop_me.lua", action = "edit", change = "601" } }
					end
					return {}
				end),
				describe = function(cl, cb)
					vim.schedule(function()
						cb(nil, { change = cl, status = "pending", client = "test_client", files = {} })
					end)
				end,
				revert = function(opts, cb)
					table.insert(revert_calls, opts)
					reverted = true
					vim.schedule(function()
						cb(nil, { { action = "reverted" } })
					end)
				end,
			}, function()
				cache.reset()
				local buf = make_buf("p4://601")
				load(buf)
				assert.are_equal(1, #entry_lines(buf))
				vim.api.nvim_buf_set_lines(buf, 2, 3, false, {})
				vim.bo[buf].modified = true
				vim.async.await(crude.save_buffer(buf))
				assert.are_equal(1, #revert_calls)
				assert.is_true(revert_calls[1].keep_workspace_files)
				assert.are_equal(0, #entry_lines(buf))
			end)
		end)
	end)
end)
