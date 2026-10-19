#!/usr/bin/env nu

# Test runner and interactive environment for perforce.nvim
#
# Usage:
#   nu test.nu        # Interactive mode: launches clean Neovim with perforce.nvim + crude.nvim and split demo buffers
#   nu test.nu -t     # Headless test mode: runs the automated test suite
def --wrapped main [
    --test (-t)     # Run automated test suite in headless mode
    ...args: string # Extra arguments passed to nvim in interactive mode
] {
    let repo_dir = $env.FILE_PWD
    if $test {
        let runner = ($repo_dir | path join "tests" "run.lua")
        ^nvim --clean --headless -u NONE -l $runner
    } else {
        let interactive = ($repo_dir | path join "tests" "interactive.lua")
        if ($args | is-empty) {
            ^nvim --clean -u $interactive
        } else {
            ^nvim --clean -u $interactive ...$args
        }
    }
}
