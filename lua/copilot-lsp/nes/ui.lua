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
