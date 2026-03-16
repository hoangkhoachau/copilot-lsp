local errs = require("copilot-lsp.errors")
local nes_ui = require("copilot-lsp.nes.ui")
local utils = require("copilot-lsp.util")

local M = {}

local nes_ns = vim.api.nvim_create_namespace("copilotlsp.nes")

-- Per-client request tracking for cancellation
M._requests = {} -- client_id -> request_id
M._latest_seq = {} -- client_id -> integer

--- Cancel any in-flight NES request for all tracked clients
function M.cancel()
    for client_id, req_id in pairs(M._requests) do
        local client = vim.lsp.get_client_by_id(client_id)
        if client then
            client:cancel_request(req_id)
        end
    end
    M._requests = {}
end

---@param err lsp.ResponseError?
---@param result copilotlsp.copilotInlineEditResponse
---@param ctx lsp.HandlerContext
---@param seq integer sequence number at time of request
local function handle_nes_response(err, result, ctx, seq)
    -- Remove from in-flight tracking
    if M._requests[ctx.client_id] == ctx.request_id then
        M._requests[ctx.client_id] = nil
    end

    -- Stale response: a newer request was already made
    if M._latest_seq[ctx.client_id] ~= seq then
        return
    end

    if err then
        vim.notify("[copilot-lsp] " .. err.message)
        return
    end
    -- Validate buffer still exists before processing response
    if not vim.api.nvim_buf_is_valid(ctx.bufnr) then
        return
    end
    for _, edit in ipairs(result.edits) do
        --- Convert to textEdit fields
        edit.newText = edit.text
    end
    if nes_ui._display_next_suggestion(ctx.bufnr, nes_ns, result.edits) then
        local client = vim.lsp.get_client_by_id(ctx.client_id)
        assert(client, errs.ErrNotStarted)
        client:notify("textDocument/didShowInlineEdit", {
            item = {
                command = result.edits[1].command,
            },
        })
    end
end

--- Requests the NextEditSuggestion from the current cursor position
---@param copilot_lss? vim.lsp.Client|string
function M.request_nes(copilot_lss)
    local bufnr = vim.api.nvim_get_current_buf()
    if type(copilot_lss) == "string" then
        copilot_lss = vim.lsp.get_clients({ name = copilot_lss })[1]
    end
    assert(copilot_lss, errs.ErrNotStarted)
    if copilot_lss.attached_buffers[bufnr] then
        -- Cancel any previous in-flight request
        M.cancel()

        -- Increment sequence counter for this client
        local client_id = copilot_lss.id
        local seq = (M._latest_seq[client_id] or 0) + 1
        M._latest_seq[client_id] = seq

        local version = vim.lsp.util.buf_versions[bufnr]
        local pos_params = vim.lsp.util.make_position_params(0, "utf-16")
        ---@diagnostic disable-next-line: inject-field
        pos_params.textDocument.version = version

        local ok, req_id = copilot_lss:request(
            "textDocument/copilotInlineEdit",
            pos_params,
            function(err, result, ctx)
                handle_nes_response(err, result, ctx, seq)
            end
        )
        if ok and req_id then
            M._requests[client_id] = req_id
        end
    end
end

--- Walks the cursor to the start of the edit.
--- This function returns false if there is no edit to apply or if the cursor is already at the start position of the
--- edit.
---@param bufnr? integer
---@return boolean --if the cursor walked
function M.walk_cursor_start_edit(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return false
    end

    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local cursor_row, _ = unpack(vim.api.nvim_win_get_cursor(0))
    if state.range.start.line >= total_lines then
        -- If the start line is beyond the end of the buffer then we can't walk there
        -- if we are at the end of the buffer, we've walked as we can
        if cursor_row == total_lines then
            return false
        end
        -- if not, walk to the end of the buffer instead
        vim.lsp.util.show_document({
            uri = state.textDocument.uri,
            range = {
                start = { line = total_lines - 1, character = 0 },
                ["end"] = { line = total_lines - 1, character = 0 },
            },
        }, "utf-16", { focus = true })
        return true
    end
    if cursor_row - 1 ~= state.range.start.line then
        vim.b[bufnr].nes_jump = true
        -- Since we are async, we check to see if the buffer has changed
        if vim.api.nvim_get_current_buf() ~= vim.uri_to_bufnr(state.textDocument.uri) then
            return false
        end

        ---@type lsp.Location
        local jump_loc_before = {
            uri = state.textDocument.uri,
            range = {
                start = state.range["start"],
                ["end"] = state.range["start"],
            },
        }

        vim.schedule(function()
            if utils.is_named_buffer(state.textDocument.uri) then
                vim.lsp.util.show_document(jump_loc_before, "utf-16", { focus = true })
            else
                vim.api.nvim_win_set_cursor(0, { state.range.start.line + 1, state.range.start.character })
            end
        end)
        return true
    else
        return false
    end
end

--- Walks the cursor to the end of the edit.
--- This function returns false if there is no edit to apply or if the cursor is already at the end position of the
--- edit
---@param bufnr? integer
---@return boolean --if the cursor walked
function M.walk_cursor_end_edit(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return false
    end
    ---@type lsp.Location
    local jump_loc_after = {
        uri = state.textDocument.uri,
        range = {
            start = state.range["end"],
            ["end"] = state.range["end"],
        },
    }
    --NOTE: If last line is deletion, then this may be outside of the buffer
    vim.schedule(function()
        -- Since we are async, we check to see if the buffer has changed
        if vim.api.nvim_get_current_buf() ~= bufnr then
            return
        end

        if utils.is_named_buffer(state.textDocument.uri) then
            pcall(vim.lsp.util.show_document, jump_loc_after, "utf-16", { focus = true })
        else
            pcall(vim.api.nvim_win_set_cursor, 0, { state.range["end"].line + 1, state.range["end"].character })
        end
    end)
    return true
end

--- This function applies the pending nes edit to the current buffer and then clears the marks for the pending
--- suggestion
---@param bufnr? integer
---@return boolean --if the nes was applied
function M.apply_pending_nes(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()

    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return false
    end
    vim.schedule(function()
        utils.apply_inline_edit(state)
        vim.b[bufnr].nes_jump = false
        nes_ui.clear_suggestion(bufnr, nes_ns)
        -- Re-trigger suggestions after applying
        vim.api.nvim_exec_autocmds("User", { pattern = "CopilotLspNesDone" })
    end)
    return true
end

---@param bufnr? integer
function M.clear_suggestion(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    nes_ui.clear_suggestion(bufnr, nes_ns)
end

--- Clear the current suggestion if it exists
---@return boolean -- true if a suggestion was cleared, false if no suggestion existed
function M.clear()
    local buf = vim.api.nvim_get_current_buf()
    if vim.b[buf].nes_state then
        local ns = vim.b[buf].copilotlsp_nes_namespace_id or nes_ns
        nes_ui.clear_suggestion(buf, ns)
        return true
    end
    return false
end

---@param client vim.lsp.Client
---@param au integer
function M.lsp_on_init(client, au)
    local cfg = require("copilot-lsp.config").config
    local debounced_request =
        utils.debounce(M.request_nes, cfg.nes.debounce)
    local debounced_focus =
        utils.debounce(function()
            local td_params = vim.lsp.util.make_text_document_params()
            client:notify("textDocument/didFocus", {
                textDocument = {
                    uri = td_params.uri,
                },
            })
        end, 10)

    -- Trigger: fire NES request after leaving insert / text changed in normal / after apply
    -- Parse "ModeChanged i:n" style events: split on space
    local trigger_evts = {}
    local trigger_patterns = {}
    for _, ev in ipairs(cfg.nes.trigger.events) do
        local evt, pat = ev:match("^(%S+)%s*(.*)")
        table.insert(trigger_evts, evt)
        table.insert(trigger_patterns, pat ~= "" and pat or nil)
    end
    -- Register each trigger event separately (to support User events with patterns)
    for i, evt in ipairs(trigger_evts) do
        local pattern = trigger_patterns[i]
        local autocmd_opts = {
            callback = function()
                debounced_request(client)
            end,
            group = au,
        }
        if evt == "User" then
            autocmd_opts.pattern = pattern
        else
            -- For ModeChanged i:n, pattern is "i:n"
            if pattern then
                autocmd_opts.pattern = pattern
            end
        end
        vim.api.nvim_create_autocmd(evt, autocmd_opts)
    end

    -- Clear: clear suggestion on InsertEnter and TextChangedI
    vim.api.nvim_create_autocmd(cfg.nes.clear.events, {
        callback = function()
            M.clear()
        end,
        group = au,
    })

    -- Clear on Escape key
    if cfg.nes.clear.esc then
        vim.on_key(function(key)
            if key == "\27" then -- ESC byte
                vim.schedule(function()
                    M.clear()
                end)
            end
        end, nes_ns)
    end

    -- didFocus on buffer/window enter
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        callback = function()
            debounced_focus()
        end,
        group = au,
    })
end

return M
