local M = {}

---@param bufnr integer
---@param ns_id integer
local function _dismiss_suggestion(bufnr, ns_id)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
end

---@param bufnr? integer
---@param ns_id integer
function M.clear_suggestion(bufnr, ns_id)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    -- Validate buffer exists before accessing buffer-scoped variables
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    if vim.b[bufnr].nes_jump then
        vim.b[bufnr].nes_jump = false
        return
    end
    _dismiss_suggestion(bufnr, ns_id)
    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return
    end

    vim.b[bufnr].nes_state = nil
end

--- Check if a 0-indexed line is visible in the current window.
---@param line integer 0-indexed
---@return boolean
local function is_line_visible(line)
    local win = vim.api.nvim_get_current_win()
    local top = vim.fn.line("w0", win) - 1 -- 0-indexed
    local bot = vim.fn.line("w$", win) - 1 -- 0-indexed
    return line >= top and line <= bot
end

---@private
---@param bufnr integer
---@param ns_id integer
---@param edits copilotlsp.InlineEdit[]
---@return boolean
function M._display_next_suggestion(bufnr, ns_id, edits)
    M.clear_suggestion(bufnr, ns_id)
    if not edits or #edits == 0 then
        return false
    end

    local suggestion = edits[1]
    local edit_line = suggestion.range.start.line

    -- Long-distance: if the edit is off-screen, show a hint at the cursor instead
    if not is_line_visible(edit_line) then
        local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
        local direction = edit_line < cursor_row and "↑" or "↓"
        local hint = string.format(" %s Edit at line %d ", direction, edit_line + 1)
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, cursor_row, 0, {
            virt_text = { { hint, "CopilotLspNesHint" } },
            virt_text_pos = "eol",
        })
        vim.b[bufnr].nes_state = suggestion
        vim.b[bufnr].copilotlsp_nes_namespace_id = ns_id
        return true
    end

    -- Use diff.compute() for inline/block highlighting
    local extmarks = require("copilot-lsp.nes.diff").compute(bufnr, suggestion, vim.bo[bufnr].filetype)
    for _, ext in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, ext.line, ext.col, ext.opts)
    end

    vim.b[bufnr].nes_state = suggestion
    vim.b[bufnr].copilotlsp_nes_namespace_id = ns_id

    return true
end

return M
