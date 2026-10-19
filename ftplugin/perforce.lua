-- Perforce form/spec buffers (e.g. `p4 change -o`), used by perforce.plugins.crude.open_change
if vim.b.did_ftplugin then
	return
end
vim.b.did_ftplugin = true

vim.bo.commentstring = "# %s"
vim.b.undo_ftplugin = "setlocal commentstring<"
