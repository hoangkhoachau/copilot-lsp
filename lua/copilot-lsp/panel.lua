local errs = require("copilot-lsp.errors")

local M = {}

-- Per-client request tracking so callers can cancel in-flight panel requests
M._requests = {} -- client_id -> request_id

--- Cancel any in-flight panel completion request.
function M.cancel()
    for client_id, req_id in pairs(M._requests) do
        local client = vim.lsp.get_client_by_id(client_id)
        if client then
            client:cancel_request(req_id)
        end
    end
    M._requests = {}
end

--- Open a scratch buffer in a vertical split and populate it with completions.
---@param items lsp.InlineCompletionItem[]
---@param source_bufnr integer
function M._open_panel(items, source_bufnr)
    local filetype = vim.bo[source_bufnr].filetype
    local lines = {}
    for i, item in ipairs(items) do
        local sep = string.format("------ Suggestion %d ------", i)
        table.insert(lines, sep)
        local text = type(item.insertText) == "string" and item.insertText
            or (item.insertText and item.insertText.value or "")
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
            table.insert(lines, line)
        end
        table.insert(lines, "")
    end

    local panel_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[panel_bufnr].buflisted = false
    vim.bo[panel_bufnr].buftype = "nofile"
    vim.bo[panel_bufnr].bufhidden = "wipe"
    vim.bo[panel_bufnr].filetype = filetype
    vim.api.nvim_buf_set_lines(panel_bufnr, 0, -1, false, lines)

    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, panel_bufnr)
    pcall(vim.api.nvim_buf_set_name, panel_bufnr, "[Copilot Panel]")
end

--- Request "Open Copilot" style panel completions from the current cursor position.
---
--- The server may stream partial results back if `partialResultToken` is set;
--- the default callback accumulates items and opens a panel once the final
--- response arrives.
---
---@param copilot_lss? vim.lsp.Client|string LSP client or server name (defaults to "copilot_ls")
---@param callback? fun(err: lsp.ResponseError?, result: lsp.InlineCompletionList, ctx: lsp.HandlerContext)
---@param partialResultToken? string Token used to stream partial results (optional)
function M.request_panel_completion(copilot_lss, callback, partialResultToken)
    local bufnr = vim.api.nvim_get_current_buf()
    if type(copilot_lss) == "string" then
        copilot_lss = vim.lsp.get_clients({ name = copilot_lss })[1]
    end
    if not copilot_lss then
        copilot_lss = vim.lsp.get_clients({ name = "copilot_ls" })[1]
    end
    assert(copilot_lss, errs.ErrNotStarted)

    if not copilot_lss.attached_buffers[bufnr] then
        return
    end

    -- Cancel any previous in-flight panel request
    M.cancel()

    local version = vim.lsp.util.buf_versions[bufnr]
    local pos_params = vim.lsp.util.make_position_params(0, "utf-16")
    ---@type table
    local params = {
        textDocument = vim.tbl_extend("force", pos_params.textDocument, { version = version }),
        position = pos_params.position,
    }
    if partialResultToken then
        params.partialResultToken = partialResultToken
    end

    local client_id = copilot_lss.id
    local ok, req_id = copilot_lss:request("textDocument/copilotPanelCompletion", params, function(err, result, ctx)
        if M._requests[client_id] == ctx.request_id then
            M._requests[client_id] = nil
        end

        if callback then
            callback(err, result, ctx)
            return
        end

        if err then
            vim.notify("[copilot-lsp] panel completion error: " .. vim.inspect(err), vim.log.levels.ERROR)
            return
        end

        if not result or not result.items or #result.items == 0 then
            vim.notify("[copilot-lsp] no panel completions available", vim.log.levels.INFO)
            return
        end

        M._open_panel(result.items, bufnr)
    end)
    if ok and req_id then
        M._requests[client_id] = req_id
    elseif not ok then
        vim.notify("[copilot-lsp] failed to send panel completion request", vim.log.levels.ERROR)
    end
end

return M
