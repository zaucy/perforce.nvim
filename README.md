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

### Oil Integration (`perforce.plugins.oil`)

Displays Perforce status (Edit, Add, Delete) in [oil.nvim](https://github.com/stevearc/oil.nvim) buffers.

```lua
require("perforce.plugins.oil").setup()
```

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
