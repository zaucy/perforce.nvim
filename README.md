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

Integrates Perforce with [crude.nvim](https://github.com/zaucy/crude.nvim). Changelists are edited as plain text buffers where each line is a full depot path (e.g. `//depot/my_project/src/main.cpp`).

Nothing is registered automatically. Register the provider (and optionally the crude-fs signs extension) yourself:

```lua
local crude = require("crude")
local p4_crude = require("perforce.plugins.crude")

crude.register_provider("perforce", p4_crude.provider)
crude.register_extension("crude-fs-p4", p4_crude.fs_signs)

-- Both are callable to create configured instances:
-- crude.register_provider("perforce", p4_crude.provider({ delete_action = "revert", history_max = 100 }))
-- crude.register_extension("crude-fs-p4", p4_crude.fs_signs({ propagate_dir_status = false }))

-- Keymaps
vim.keymap.set("n", "<leader>pp", function() p4_crude.open() end, { desc = "Perforce pending changelists" })
vim.keymap.set("n", "<leader>po", function() p4_crude.open("opened") end, { desc = "Perforce changelists with opened files" })
vim.keymap.set("n", "<leader>ph", function() p4_crude.open("history") end, { desc = "Perforce server history" })
vim.keymap.set("n", "<leader>pd", function() p4_crude.open("default") end, { desc = "Perforce default changelist" })
vim.keymap.set("n", "<leader>pe", function()
  -- changelist under the cursor in an overview, otherwise the current changelist buffer, otherwise default
  local entry = p4_crude.cursor_entry()
  local cl = entry and entry.meta and entry.meta.changelist
  if not cl then
    local u = p4_crude.url.try_parse(vim.api.nvim_buf_get_name(0))
    cl = u and u.changelist or "default"
  end
  p4_crude.open_change(cl)
end, { desc = "Perforce edit change spec" })
```

#### Buffers

| URL | Contents | Columns |
| --- | --- | --- |
| `p4://` | Pending changelists of the current user + client | user, files, change, description |
| `p4://opened` | Only changelists that currently have opened files | user, files, change, description |
| `p4://history` | Latest changelists server-wide (`history_max`) | user, status, change, description |
| `p4://default`, `p4://<cl>` | Files in the changelist (full depot paths) | action, file |

Changelists are sorted with `default` first, then newest first. Overviews are read-only. Changelists that are submitted, shelved-only, or owned by another client open read-only.

#### Editing changelist buffers (`:w` to apply)

- **Move between changelists**: cut a line in `p4://default` (`dd`), paste it into `p4://12345` (`p`) and save: `p4 reopen -c 12345 <file>`. The source changelist does not revert moved files.
- **Rename**: edit a depot path: `p4 move`.
- **Open a file**: type a depot or local path on a new line. Already opened files are reopened, files in the depot are opened for `edit`, new files are `add`ed. Wildcards (`...`, `*`, `%`) and revision specifiers (`#`, `@`) are rejected.
- **Remove**: delete a line. With the default `delete_action = "revert_keep"` this runs `p4 revert -k` (the workspace file is kept). Use `"revert"` for a plain `p4 revert`, or `"disabled"` to refuse.

p4 warnings (e.g. "file(s) not opened on this client") are reported as errors for the affected lines.

#### Navigation

- `<CR>` on a changelist in an overview opens it. On a file it opens the local workspace file (resolved via `p4 where`), or shows the depot revision read-only via `p4 print` when the file isn't on disk.
- `-` in a changelist goes back to the overview it was opened from (`p4://` by default). `-` in `p4://opened` / `p4://history` goes to `p4://`, and `-` in `p4://` opens the workspace root (`clientRoot`).
- Opening a `p4://` buffer (e.g. `:edit p4://default` from a keymap) focuses the row for the buffer you came from. From an opened file, a changelist buffer focuses that file and `p4://` / `p4://opened` focus the changelist it's opened in. From a `p4://<cl>` buffer, the overviews focus that changelist.

#### Change specification editor

`p4_crude.open_change(cl, opts?)` opens `p4 change -o <cl>` in a centered float (`opts.split` / `opts.vertical` for a split). Save with `:w` (`p4 change -i`), close with `q`.

#### API

- `p4_crude.open(target?)`: open `p4://`, `"opened"`, `"history"`, `"default"`, a changelist number, or a full `p4://` URL.
- `p4_crude.open_change(cl?, opts?)`: change spec editor.
- `p4_crude.cursor_entry(bufnr?)`: crude entry under the cursor (`entry.meta.changelist`, `entry.meta.depot_file`, ...).
- `p4_crude.refresh_buffers()`: reload unmodified `p4://` buffers.
- `User PerforceOpenedChanged` autocmd: fired after anything changes the set of opened files (saving changelist buffers or change specs). The crude-fs signs listen to it.

Highlight groups: `PerforceCrudeActionEdit`, `PerforceCrudeActionAdd`, `PerforceCrudeActionDelete`, `PerforceCrudeActionMove`, `PerforceCrudeActionIntegrate`, `PerforceCrudeStatusPending`, `PerforceCrudeStatusSubmitted`, `PerforceCrudeStatusShelved`, `PerforceCrudeUser`, `PerforceCrudeCount`, `PerforceCrudeChange`, `PerforceCrudeDefault`, `PerforceCrudeDescription`.

### Crude-fs Signs (`perforce.plugins.crude.fs_signs`)

A crude.nvim extension that marks files opened in your Perforce workspace in the sign column of `crude-fs` buffers. Directories that contain opened files get a directory sign.

```lua
crude.register_extension("crude-fs-p4", require("perforce.plugins.crude").fs_signs({
  providers = { "crude-fs", "fs" }, -- crude provider ids to attach to
  propagate_dir_status = true,      -- mark directories containing opened files
  refresh_on_focus = true,          -- refresh on FocusGained (p4 commands run outside Neovim)
  priority = 20,
  signs = {
    edit = { text = "M", hl = "PerforceSignEdit" },
    add = { text = "A", hl = "PerforceSignAdd" },
    delete = { text = "D", hl = "PerforceSignDelete" },
    move = { text = "R", hl = "PerforceSignMove" },
    integrate = { text = "I", hl = "PerforceSignIntegrate" },
    dir = { text = "*", hl = "PerforceSignDir" },
  },
}))
```

| Sign | p4 actions |
| --- | --- |
| `M` | edit |
| `A` | add, branch, import |
| `D` | delete, move/delete, purge, archive |
| `R` | move/add |
| `I` | integrate |
| `*` | directory containing opened files |

Signs come from a single `p4 fstat -Ro` over the directory and refresh when the buffer reloads, on `User PerforceOpenedChanged`, and on `FocusGained`. Directories outside a Perforce workspace are left alone.

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
