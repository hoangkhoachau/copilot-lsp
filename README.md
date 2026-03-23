# Copilot LSP Configuration for Neovim

## Features

A Neovim plugin that implements the [Copilot Language Server Protocol](https://github.com/github/copilot-language-server-release).

### Implemented LSP Features

| Feature | Method | Status |
|---------|--------|--------|
| Initialization | `initialize` / `initialized` | ✅ (Neovim built-in) |
| Configuration | `workspace/didChangeConfiguration` | ✅ (Neovim built-in) |
| Workspace Folders | `workspace/didChangeWorkspaceFolders` | ✅ (Neovim built-in) |
| Text Document Sync | `textDocument/didOpen/didChange/didClose` | ✅ (Neovim built-in) |
| Text Document Focusing | `textDocument/didFocus` | ✅ |
| Status Notification | `didChangeStatus` | ✅ |
| Sign In | `signIn` | ✅ |
| Sign Out | `signOut` | ✅ |
| Inline Completions | `textDocument/inlineCompletion` | ✅ (via blink-cmp) |
| Show Completion Telemetry | `textDocument/didShowCompletion` | ✅ |
| Partial Accept Telemetry | `textDocument/didPartiallyAcceptCompletion` | ✅ |
| Next Edit Suggestions | `textDocument/copilotInlineEdit` | ✅ |
| Show Inline Edit Telemetry | `textDocument/didShowInlineEdit` | ✅ |
| Panel Completions | `textDocument/copilotPanelCompletion` | ✅ |
| Cancellation | `$/cancelRequest` | ✅ (Neovim built-in) |
| Logs | `window/logMessage` | ✅ (Neovim built-in) |
| Messages | `window/showMessageRequest` | ✅ (Neovim built-in) |

## Usage

To use the plugin, add the following to your Neovim configuration:

```lua
return {
    "copilotlsp-nvim/copilot-lsp",
    init = function()
        vim.g.copilot_nes_debounce = 500
        vim.lsp.enable("copilot_ls")
        vim.keymap.set("n", "<tab>", function()
            local bufnr = vim.api.nvim_get_current_buf()
            local state = vim.b[bufnr].nes_state
            if state then
                -- Try to jump to the start of the suggestion edit.
                -- If already at the start, then apply the pending suggestion and jump to the end of the edit.
                local _ = require("copilot-lsp.nes").walk_cursor_start_edit()
                    or (
                        require("copilot-lsp.nes").apply_pending_nes()
                        and require("copilot-lsp.nes").walk_cursor_end_edit()
                    )
                return nil
            else
                -- Resolving the terminal's inability to distinguish between `TAB` and `<C-i>` in normal mode
                return "<C-i>"
            end
        end, { desc = "Accept Copilot NES suggestion", expr = true })
    end,
}
```

#### Clearing suggestions with Escape

You can map the `<Esc>` key to clear suggestions while preserving its other functionality:

```lua
-- Clear copilot suggestion with Esc if visible, otherwise preserve default Esc behavior
vim.keymap.set("n", "<esc>", function()
    if not require("copilot-lsp.nes").clear() then
        -- fallback to other functionality
    end
end, { desc = "Clear Copilot suggestion or fallback" })
```

#### Sign Out

```lua
-- Sign out of GitHub Copilot
vim.keymap.set("n", "<leader>co", function()
    require("copilot-lsp").sign_out()
end, { desc = "Copilot sign out" })
```

#### Panel Completions ("Open Copilot")

Open a vertical split showing multiple completion suggestions for the current
cursor position:

```lua
vim.keymap.set("n", "<leader>cp", function()
    local client = vim.lsp.get_clients({ name = "copilot_ls" })[1]
    require("copilot-lsp.panel").request_panel_completion(client)
end, { desc = "Open Copilot panel completions" })
```

A custom callback can be supplied to handle the results yourself:

```lua
require("copilot-lsp.panel").request_panel_completion(client, function(err, result, _ctx)
    if err or not result then return end
    for _, item in ipairs(result.items) do
        print(item.insertText)
    end
end)
```

#### Inline Completion Telemetry

When a completion plugin (e.g. blink-cmp) displays or partially accepts an
inline completion, notify the server for telemetry:

```lua
local completion = require("copilot-lsp.completion")
local client = vim.lsp.get_clients({ name = "copilot_ls" })[1]

-- Call after a suggestion becomes visible
completion.did_show_completion(client, item)

-- Call after the user accepts only part of the suggestion
completion.did_partially_accept_completion(client, item, accepted_length)
```

## Default Configuration

### NES (Next Edit Suggestion) Smart Clearing

You don’t need to configure anything, but you can customize the defaults:
`move_count_threshold` is the most important. It controls how many cursor moves happen before suggestions are cleared. Higher = slower to clear.

```lua
require('copilot-lsp').setup({
  nes = {
    move_count_threshold = 3,   -- Clear after 3 cursor movements
  }
})
```

### Blink Integration

```lua
return {
    keymap = {
        preset = "super-tab",
        ["<Tab>"] = {
            function(cmp)
                if vim.b[vim.api.nvim_get_current_buf()].nes_state then
                    cmp.hide()
                    return (
                        require("copilot-lsp.nes").apply_pending_nes()
                        and require("copilot-lsp.nes").walk_cursor_end_edit()
                    )
                end
                if cmp.snippet_active() then
                    return cmp.accept()
                else
                    return cmp.select_and_accept()
                end
            end,
            "snippet_forward",
            "fallback",
        },
    },
}
```

It can also be combined with [fang2hou/blink-copilot](https://github.com/fang2hou/blink-copilot) to get inline completions.
Just add the completion source to your Blink configuration and it will integrate

# Requirements

- Copilot LSP installed via Mason or system and on PATH

### Screenshots

#### NES

![JS Correction](https://github.com/user-attachments/assets/8941f8f9-7d1b-4521-b8e9-f1dcd12d31e9)
![Go Insertion](https://github.com/user-attachments/assets/2c0c4ad9-873b-4860-9eff-ecdb76007234)

<https://github.com/user-attachments/assets/1d5bed4a-fd0a-491f-91f3-a3335cc28682>
