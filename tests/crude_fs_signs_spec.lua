local helper = require("test_helper")
local assert = helper.assert
local perforce = require("perforce")
local crude = require("crude")
local cache = require("crude.cache")
local extension = require("crude.extension")
local view = require("crude.view")
local fs_prov = require("crude.providers.fs")
local p4_crude = require("perforce.plugins.crude")
local fs_signs = require("perforce.plugins.crude.fs_signs")

local EXT_ID = "crude-fs-p4"
local is_windows = vim.fn.has("win32") == 1

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

local function make_tree()
	local root = vim.fs.normalize(vim.fn.tempname())
	vim.fn.mkdir(root .. "/sub/deep", "p")
	vim.fn.writefile({ "a" }, root .. "/a.txt")
	vim.fn.writefile({ "b" }, root .. "/b.txt")
	vim.fn.writefile({ "c" }, root .. "/sub/c.txt")
	vim.fn.writefile({ "d" }, root .. "/sub/deep/d.txt")
	return root
end

---Local path in p4's native form (backslashes on Windows)
local function native(path)
	return is_windows and path:gsub("/", "\\") or path
end

---Install mocks for get_workspace_root and fstat. Returns a state table and a restore function.
---@param opts { root?: string|false, records?: table[]|fun(): table[], manual?: boolean }
local function install_mocks(opts)
	local orig_root, orig_fstat = perforce.get_workspace_root, perforce.fstat
	local state = { fstat_calls = {}, pending = {} }
	perforce.get_workspace_root = function(_, cb)
		cb(opts.root or nil)
	end
	perforce.fstat = function(o, cb)
		table.insert(state.fstat_calls, o)
		if opts.manual then
			table.insert(state.pending, cb)
			return
		end
		vim.schedule(function()
			local recs = type(opts.records) == "function" and opts.records() or opts.records or {}
			cb(nil, recs)
		end)
	end
	return state, function()
		perforce.get_workspace_root, perforce.fstat = orig_root, orig_fstat
	end
end

---Register crude-fs + the extension and load `dir` in the current window
---@param dir string
---@param ext_opts? table
---@return integer bufnr
local function load_dir(dir, ext_opts)
	extension.reset()
	cache.reset()
	local p = fs_prov.create({ replace_netrw = false, columns = false })
	crude.register_provider("fs", p)
	crude.register_extension(EXT_ID, ext_opts and p4_crude.fs_signs(ext_opts) or p4_crude.fs_signs)
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, dir)
	-- Load before entering: crude's BufEnter autoload would otherwise load (and attach) a second time
	vim.async.await(crude.load_buffer(buf, p, "fs"))
	vim.api.nvim_set_current_buf(buf)
	return buf
end

---Map of entry name -> sign text, read from the extension's extmarks
---@param buf integer
---@return table<string, string>
local function signs_by_name(buf)
	local ns = view.get_extension_ns(EXT_ID)
	local out = {}
	for _, em in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		local details = em[4]
		if details.sign_text then
			local line = vim.api.nvim_buf_get_lines(buf, em[2], em[2] + 1, false)[1] or ""
			local name = line:gsub("^@@%S+%s+", "")
			out[vim.trim(name)] = vim.trim(details.sign_text)
		end
	end
	return out
end

local function ext_state(buf)
	return extension.get_context(buf, EXT_ID).state
end

describe("perforce crude-fs signs extension", function()
	describe("build_status", function()
		it("maps direct children and propagates nested files to their top-level folder", function()
			local status = fs_signs.build_status({
				{ clientFile = native("/ws/proj/a.txt"), action = "edit", change = "default" },
				{ clientFile = native("/ws/proj/n.txt"), action = "move/add", change = "5" },
				{ clientFile = native("/ws/proj/sub/c.txt"), action = "add" },
				{ clientFile = native("/ws/proj/sub/deep/d.txt"), action = "delete" },
				{ clientFile = native("/ws/other/x.txt"), action = "edit" },
				{ clientFile = native("/ws/projector/y.txt"), action = "edit" },
			}, "/ws/proj/", true)
			assert.are_equal("edit", status["a.txt"].kind)
			assert.are_equal("default", status["a.txt"].change)
			assert.are_equal("move", status["n.txt"].kind)
			assert.are_equal("dir", status["sub"].kind)
			assert.are_equal(2, status["sub"].count)
			assert.is_nil(status["x.txt"])
			assert.is_nil(status["y.txt"])
			assert.is_nil(status["projector"])
		end)

		it("does not propagate when disabled and maps unknown actions to edit", function()
			local status = fs_signs.build_status({
				{ clientFile = "/ws/sub/c.txt", action = "add" },
				{ clientFile = "/ws/weird.txt", action = "something-new" },
			}, "/ws", false)
			assert.is_nil(status["sub"])
			assert.are_equal("edit", status["weird.txt"].kind)
		end)

		if is_windows then
			it("matches paths case-insensitively on Windows", function()
				local status = fs_signs.build_status({
					{ clientFile = "C:\\WS\\Proj\\A.TXT", action = "edit" },
				}, "c:/ws/proj", true)
				assert.are_equal("edit", status["a.txt"].kind)
			end)
		end
	end)

	describe("crude-fs buffers", function()
		it("shows signs for opened files and folders containing opened files", function()
			local root = make_tree()
			local st, restore = install_mocks({
				root = root,
				records = {
					{ clientFile = native(root .. "/a.txt"), action = "edit", change = "default" },
					{ clientFile = native(root .. "/sub/deep/d.txt"), action = "add", change = "12" },
				},
			})
			local ok, err = pcall(function()
				local buf = load_dir(root)
				wait_until(function()
					return ext_state(buf).status ~= nil
				end)
				local signs = signs_by_name(buf)
				assert.are_equal("M", signs["a.txt"])
				assert.are_equal("*", signs["sub/"])
				assert.is_nil(signs["b.txt"])

				local call = st.fstat_calls[1]
				assert.is_true(call.opened_only)
				assert.are_equal(root, call.cwd)
				assert.matches("%.%.%.$", call.files[1])
				vim.api.nvim_buf_delete(buf, { force = true })
			end)
			restore()
			vim.fn.delete(root, "rf")
			assert(ok, err)
		end)

		it("matches Windows-style client paths with different case", function()
			if not is_windows then
				return
			end
			local root = make_tree()
			local _, restore = install_mocks({
				root = root,
				records = { { clientFile = native(root:upper() .. "/B.TXT"), action = "delete" } },
			})
			local ok, err = pcall(function()
				local buf = load_dir(root)
				wait_until(function()
					return ext_state(buf).status ~= nil
				end)
				assert.are_equal("D", signs_by_name(buf)["b.txt"])
				vim.api.nvim_buf_delete(buf, { force = true })
			end)
			restore()
			vim.fn.delete(root, "rf")
			assert(ok, err)
		end)

		it("does nothing outside a Perforce workspace", function()
			local root = make_tree()
			local st, restore = install_mocks({ root = false })
			local ok, err = pcall(function()
				local buf = load_dir(root)
				vim.async.sleep(50)
				assert.are_equal(0, #st.fstat_calls)
				assert.same({}, signs_by_name(buf))
				vim.api.nvim_buf_delete(buf, { force = true })
			end)
			restore()
			vim.fn.delete(root, "rf")
			assert(ok, err)
		end)

		it("refreshes on User PerforceOpenedChanged", function()
			local root = make_tree()
			local records = { { clientFile = native(root .. "/a.txt"), action = "edit" } }
			local st, restore = install_mocks({
				root = root,
				records = function()
					return records
				end,
			})
			local ok, err = pcall(function()
				local buf = load_dir(root)
				wait_until(function()
					return ext_state(buf).status ~= nil
				end)
				assert.is_nil(signs_by_name(buf)["b.txt"])

				records = { { clientFile = native(root .. "/b.txt"), action = "add" } }
				vim.api.nvim_exec_autocmds("User", { pattern = "PerforceOpenedChanged" })
				wait_until(function()
					return signs_by_name(buf)["b.txt"] == "A"
				end)
				assert.is_nil(signs_by_name(buf)["a.txt"])
				assert.are_equal(2, #st.fstat_calls)
				vim.api.nvim_buf_delete(buf, { force = true })
			end)
			restore()
			vim.fn.delete(root, "rf")
			assert(ok, err)
		end)

		it("ignores stale responses that arrive after a newer refresh", function()
			local root = make_tree()
			local st, restore = install_mocks({ root = root, manual = true })
			local ok, err = pcall(function()
				local buf = load_dir(root)
				assert.are_equal(1, #st.pending)
				st.pending[1](nil, {})
				assert.same({}, signs_by_name(buf))

				vim.api.nvim_exec_autocmds("User", { pattern = "PerforceOpenedChanged" })
				vim.api.nvim_exec_autocmds("User", { pattern = "PerforceOpenedChanged" })
				assert.are_equal(3, #st.pending)

				-- Newest answers first, then the older one arrives late
				st.pending[3](nil, { { clientFile = native(root .. "/b.txt"), action = "add" } })
				st.pending[2](nil, { { clientFile = native(root .. "/a.txt"), action = "edit" } })

				local signs = signs_by_name(buf)
				assert.are_equal("A", signs["b.txt"])
				assert.is_nil(signs["a.txt"])
				assert.is_false(ext_state(buf).pending)
				vim.api.nvim_buf_delete(buf, { force = true })
			end)
			restore()
			vim.fn.delete(root, "rf")
			assert(ok, err)
		end)

		it("respects custom signs and propagate_dir_status = false", function()
			local root = make_tree()
			local _, restore = install_mocks({
				root = root,
				records = {
					{ clientFile = native(root .. "/a.txt"), action = "edit" },
					{ clientFile = native(root .. "/sub/c.txt"), action = "edit" },
				},
			})
			local ok, err = pcall(function()
				local buf = load_dir(root, { propagate_dir_status = false, signs = { edit = { text = "~" } } })
				wait_until(function()
					return ext_state(buf).status ~= nil
				end)
				local signs = signs_by_name(buf)
				assert.are_equal("~", signs["a.txt"])
				assert.is_nil(signs["sub/"])
				vim.api.nvim_buf_delete(buf, { force = true })
			end)
			restore()
			vim.fn.delete(root, "rf")
			assert(ok, err)
		end)
	end)
end)
