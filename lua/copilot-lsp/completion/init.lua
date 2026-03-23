local M = {}

---@param _results table<integer, { err: lsp.ResponseError, result: lsp.InlineCompletionList}>
---@param _ctx lsp.HandlerContext
---@param _config table
local function handle_inlineCompletion_response(_results, _ctx, _config)
    -- -- Filter errors from results
    -- local results1 = {} --- @type table<integer,lsp.InlineCompletionList>
    --
    -- for client_id, resp in pairs(results) do
    --     local err, result = resp.err, resp.result
    --     if err then
    --         vim.lsp.log.error(err.code, err.message)
    --     elseif result then
    --         results1[client_id] = result
    --     end
    -- end
    --
    -- for _, result in pairs(results1) do
    --     --TODO: Ghost text for completions
    --     -- This is where we show the completion results
    --     -- However, the LSP being named "copilot_ls" is enough for blink-cmp to show the completion
    -- end
end

---@param type lsp.InlineCompletionTriggerKind
function M.request_inline_completion(type)
    local params = vim.tbl_deep_extend("keep", vim.lsp.util.make_position_params(0, "utf-16"), {
        textDocument = vim.lsp.util.make_text_document_params(),
        position = vim.lsp.util.make_position_params(0, "utf-16"),
        context = {
            triggerKind = type,
        },
        formattingOptions = {
            --TODO: Grab this from editor also
            tabSize = 4,
            insertSpaces = true,
        },
    })
    vim.lsp.buf_request_all(0, "textDocument/inlineCompletion", params, handle_inlineCompletion_response)
end

--- Notify the language server that a completion item was displayed to the user.
--- This should be called whenever a completion suggestion becomes visible.
---@param client vim.lsp.Client
---@param item lsp.InlineCompletionItem
function M.did_show_completion(client, item)
    client:notify("textDocument/didShowCompletion", { item = item })
end

--- Notify the language server that the user partially accepted a completion.
--- `accepted_length` is the number of UTF-16 codepoints accepted, measured
--- from the start of `insertText` to the end of the accepted portion.
---@param client vim.lsp.Client
---@param item lsp.InlineCompletionItem
---@param accepted_length integer
function M.did_partially_accept_completion(client, item, accepted_length)
    client:notify("textDocument/didPartiallyAcceptCompletion", {
        item = item,
        acceptedLength = accepted_length,
    })
end

return M
