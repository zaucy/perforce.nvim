---URL helpers for perforce crude buffers (`p4://...`).
---
--- p4://           pending changelists for the current user + client
--- p4://opened     changelists that currently have opened files
--- p4://history    latest changelists server-wide
--- p4://<cl>       files in changelist <cl> (number or "default")
local M = {}

M.scheme = "p4://"

---@alias perforce.crude.UrlKind "pending"|"opened"|"history"|"changelist"

---@class perforce.crude.Url
---@field kind perforce.crude.UrlKind
---@field changelist? string

---@type table<string, perforce.crude.UrlKind>
local OVERVIEWS = {
	[""] = "pending",
	pending = "pending",
	opened = "opened",
	history = "history",
}

---Parse a `p4://` buffer name. Errors on anything that is not a valid p4 crude URL.
---@param name string
---@return perforce.crude.Url
function M.parse(name)
	assert(type(name) == "string", "name must be a string")
	-- Also accept names that Neovim prefixed with a cwd (`C:/foo/p4://...`)
	local normalized = name:gsub("\\", "/")
	local path = normalized:match("^p4://(.*)$") or normalized:match("/p4://(.*)$")
	assert(path, string.format("Not a p4:// URL: %s", name))
	path = path:gsub("^/+", ""):gsub("/+$", "")

	local kind = OVERVIEWS[path]
	if kind then
		return { kind = kind }
	end

	assert(
		path == "default" or path:match("^%d+$"),
		string.format("Invalid changelist in p4:// URL (expected a number or 'default'): %s", name)
	)
	return { kind = "changelist", changelist = path }
end

---Like parse, but returns nil instead of erroring
---@param name string
---@return perforce.crude.Url?
function M.try_parse(name)
	local ok, res = pcall(M.parse, name)
	return ok and res or nil
end

---Format a parsed URL back into a buffer name
---@param url perforce.crude.Url
---@return string
function M.format(url)
	assert(type(url) == "table", "url must be a table")
	if url.kind == "pending" then
		return M.scheme
	elseif url.kind == "opened" or url.kind == "history" then
		return M.scheme .. url.kind
	end
	assert(url.kind == "changelist", "unknown url kind: " .. tostring(url.kind))
	assert(type(url.changelist) == "string" and url.changelist ~= "", "changelist url requires a changelist")
	return M.scheme .. url.changelist
end

---@param cl string|number
---@return string
function M.changelist(cl)
	return M.format({ kind = "changelist", changelist = tostring(cl) })
end

---@param url perforce.crude.Url
---@return boolean
function M.is_overview(url)
	return url.kind ~= "changelist"
end

return M
