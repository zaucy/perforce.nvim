# perforce.nvim

A Perforce wrapper for Neovim with optional UI plugins.

## Core API

The core API provides wrappers around common Perforce commands:

```lua
local perforce = require("perforce")

-- Get list of workspaces
perforce.workspaces({}, function(err, list) ... end)

-- Get opened files
perforce.opened({ files = { "..." } }, function(err, list) ... end)

-- Diff a file
perforce.diff("file.txt", function(err, diff_info) ... end)
```

## Plugins

### Crude Integration (`perforce.plugins.crude`)

Integrates Perforce with [crude.nvim](https://github.com/zaucy/crude.nvim):
- **Full Genuine Depot Paths**: Unlike Oil which forbids slashes in entry names and requires stripping filenames to basenames with virtual text hacks, the Crude provider renders full, native Perforce depot paths directly in the buffer (e.g. `//depot/my_project/src/main.cpp`).
- **Action Column**: Displays Perforce file actions (`edit`, `add`, `delete`, `integrate`) with appropriate syntax highlighting (`DiffChange`, `DiffAdd`, `DiffDelete`, `Special`).
- **Cross-Changelist Moves**: Move files between changelist buffers (e.g. cut a line with `dd` in `p4://default`, paste into `p4://12345` with `p`) and save (`:w`). Crude automatically detects the cross-buffer move and executes `p4 reopen -c 12345 <depotFile>`.
- **Revert on Delete**: Press `dd` on a depot path and save (`:w`) to execute `p4 revert <depotFile>`. Files moved across changelist buffers are automatically recognized and will not be reverted.
- **Rename / Move**: Edit a depot path directly and save (`:w`) to execute `p4 move`.
- **Add / Edit**: Add a new file path to a changelist buffer and save (`:w`) to execute `p4 edit` (or fallback `p4 add`).
- **Navigation & Inspection**:
  - Press `<CR>` on an overview changelist to open its buffer.
  - Press `<CR>` on a depot path to open the corresponding local workspace file (resolved via client mapping or `p4 where`), or view remote/submitted files via `p4 print`.
  - Press `-` inside any changelist buffer to navigate up to the changelist overview (`p4://opened`).
- **Changelist Specification Editor**: Run `:P4 change [changelist]` to view and edit changelist specifications (`p4 change -o / -i`) in a centered floating window.

```lua
local p4_crude = require("perforce.plugins.crude")
p4_crude.setup()

-- Keymaps
vim.keymap.set("n", "<leader>po", "<cmd>P4 opened<cr>", { desc = "Perforce opened changelists" })
vim.keymap.set("n", "<leader>pd", "<cmd>P4 default<cr>", { desc = "Perforce default changelist" })
vim.keymap.set("n", "<leader>ph", "<cmd>P4 history<cr>", { desc = "Perforce server history" })
vim.keymap.set("n", "<leader>pe", "<cmd>P4 change<cr>", { desc = "Perforce edit change spec" })
```

#### Commands:
- `:P4 [opened|history|default|<cl>]` or `:CrudeP4 [...]`: Open a Crude buffer for pending changelists, history, or a specific changelist.
- `:P4 change [changelist]`: Open changelist spec editor (`p4 change -o / -i`) for the specified changelist.
- `:edit p4://opened`: Overview of only changelists that currently have opened files.
- `:edit p4://history`: Overview of recent server-wide changelists.
- `:edit p4://default`: Flat list of files in the default changelist.
- `:edit p4://<cl>`: Flat list of files in changelist `<cl>`.

### Oil Integration (`perforce.plugins.oil`)

Integrates Perforce with [oil.nvim](https://github.com/stevearc/oil.nvim):
- **Status Indicators**: Displays Perforce status (Edit `M`, Add `A`, Delete `D`) in file buffers.
- **Changelist Buffers**: Browse pending changelists for the current user using `oil-p4://` or `p4://` URLs. Each changelist buffer displays a flat list of its opened files with status signs (`M`, `A`, `D`) and directory paths as virtual text.
- **Opened Overview (`oil-p4://opened`)**: View an overview of only the changelists that currently have opened files (with file counts and descriptions). Pressing `<CR>` on a changelist opens its flat file buffer.
- **Server History (`oil-p4://history`)**: View the latest submitted and pending changelists from everyone across the entire Perforce server. Pressing `<CR>` opens the changelist to inspect its files (read-only for submitted changelists).
- **Changelist Icons**: Changelist entries display a dedicated commit icon (``, customizable via `changelist = "..."` in Oil's `"icon"` column config) distinguishing them from ordinary folders.
- **Author Column**: Registered Oil column (`"author"`, `"user"`, or `"p4_user"`) that aligns changelist authors across overview buffers (`oil-p4://history`, `oil-p4://opened`, `oil-p4://`). Automatically enabled in changelist overview buffers without cluttering file buffers or regular filesystem Oil buffers. Highlight group `OilP4Author` defaults to `Identifier`.
- **Smart Sorting**: Changelist lists automatically place `default` at the top, followed by numeric changelists in descending order (highest/newest first). Supports sorting by author or changelist number. Files within a changelist remain in standard alphabetical order.
- **Hierarchical Navigation (`-` / `<leader>e`)**: Press `-` inside any changelist buffer to return to the overview (`history`, `opened`, or root `oil-p4://`), and press `-` again to navigate up to the filesystem workspace root in standard Oil.
- **Reopen Files Between Changelists**: Move files between changelist buffers (e.g. cut & paste between split windows) and save (`:w`) to execute `p4 reopen -c <target_cl>`.
- **Cross-adapter Moves**: Move files from standard `oil://` buffers into `oil-p4://<cl>` buffers to reopen/open them into that changelist.
- **Edit Changelist Specifications (`p4 change`)**: View and edit changelist descriptions, jobs, and file lists in a centered floating window (`p4://change/<cl>`). Save with `:w` to commit changes via `p4 change -i` and press `q` or `:wq` to close.
- **Mark Files for Edit (`p4 edit`)**: Mark the file under the cursor for edit in any Oil buffer.

```lua
-- Option A: Scoped specifically to oil-p4:// buffers (recommended if using the same key as global mappings)
require("perforce.plugins.oil").setup({
  keymaps = {
    ["<leader>ve"] = "change", -- Only maps in oil-p4:// buffers, leaves standard oil:// buffers untouched
  },
})

-- Option B: Registered in oil.nvim (contextual: changelist float if on changelist, p4 edit if on a file)
require("oil").setup({
  keymaps = {
    ["<leader>ve"] = "actions.p4_change", -- Contextual changelist editor / file edit
    ["<leader>va"] = "actions.p4_edit",   -- Dedicated p4 edit on file under cursor
  },
})

-- Open overview of changelists with opened files
vim.keymap.set("n", "<leader>po", "<cmd>OilP4 opened<cr>")

-- Open all pending changelists for current user
vim.keymap.set("n", "<leader>pc", "<cmd>OilP4<cr>")

-- Open server-wide history of latest changelists
vim.keymap.set("n", "<leader>ph", "<cmd>OilP4 history<cr>")

-- Open default changelist
vim.keymap.set("n", "<leader>pd", "<cmd>OilP4 default<cr>")
```

#### Commands:
- `:OilP4 [changelist]`: Open an Oil buffer for all pending changelists, `opened`, `history`, or a specific changelist (with tab completion).
- `:OilP4 change [changelist]`: Open changelist spec editor (`p4 change -o / -i`) for the specified changelist, or detects from current Oil changelist buffer / cursor entry.
- `:edit oil-p4://`: Browse all pending changelists for the current user/client.
- `:edit oil-p4://opened`: Overview of only changelists that currently have opened files.
- `:edit oil-p4://history`: Overview of recent server-wide changelists from all users.

### Signs Integration (`perforce.plugins.signs`)

Provides live sign column updates, line blame, and side-by-side diffing.

```lua
local signs = require("perforce.plugins.signs")
signs.setup()

-- Optional keybindings
vim.keymap.set("n", "<leader>gb", signs.blame_line)
vim.keymap.set("n", "<leader>gd", signs.diffthis)
vim.keymap.set("n", "]h", signs.next_hunk)
vim.keymap.set("n", "[h", signs.prev_hunk)
```

#### Features:
- **Live Signs**: `+` for added lines, `~` for modified, `-` for deleted. Updates in real-time.
- **Blame Line**: Shows the changelist number as virtual text for the current line.
- **Diff This**: Opens a side-by-side diff against the `have` version.
- **Hunk Navigation**: Jump between changed sections in the buffer.
