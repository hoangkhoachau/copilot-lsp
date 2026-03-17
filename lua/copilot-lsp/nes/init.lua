local errs = require("copilot-lsp.errors")
local nes_ui = require("copilot-lsp.nes.ui")
local utils = require("copilot-lsp.util")

local M = {}

local nes_ns = vim.api.nvim_create_namespace("copilotlsp.nes")

M._clients = {} -- client_id -> { inflight = {...}|nil, pending = {...}|nil }
M._latest_seq = {} -- client_id -> integer
M._last_requested = {} -- bufnr -> snapshot fingerprint
M._candidates = {} -- bufnr -> { edit, client_id, snapshot, shown }
M._insert_changed = {} -- bufnr -> boolean
M._suppressed = false

local function redraw_ruler()
    vim.schedule(function()
        pcall(vim.cmd, "redrawstatus")
    end)
end

local function get_client_state(client_id)
    local state = M._clients[client_id]
    if not state then
        state = {
            inflight = nil,
            pending = nil,
        }
        M._clients[client_id] = state
    end
    return state
end

local function get_copilot_client(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if client.name and client.name:lower():find("copilot") then
            return client
        end
    end
end

local function get_buffer_version(bufnr)
    local versions = vim.lsp.util.buf_versions
    return versions and versions[bufnr] or vim.b[bufnr].changedtick
end

local function snapshot_fingerprint(snapshot)
    return table.concat({
        snapshot.uri or "",
        tostring(snapshot.version or 0),
        tostring(snapshot.position.line or 0),
        tostring(snapshot.position.character or 0),
        snapshot.mode or "",
    }, "|")
end

local function capture_snapshot(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local version = get_buffer_version(bufnr)
    local params = vim.lsp.util.make_position_params(0, "utf-16")
    ---@diagnostic disable-next-line: inject-field
    params.textDocument.version = version
    params.context = { triggerKind = 2 }

    local snapshot = {
        bufnr = bufnr,
        mode = vim.api.nvim_get_mode().mode,
        uri = params.textDocument.uri,
        version = version,
        position = {
            line = params.position.line,
            character = params.position.character,
        },
        params = params,
    }
    snapshot.fingerprint = snapshot_fingerprint(snapshot)
    return snapshot
end

local function dismiss_view(bufnr)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local ns = vim.b[bufnr].copilotlsp_nes_namespace_id or nes_ns
    vim.b[bufnr].nes_jump = false
    nes_ui.clear_suggestion(bufnr, ns)
end

local function invalidate_candidate(bufnr)
    M._candidates[bufnr] = nil
    dismiss_view(bufnr)
    redraw_ruler()
end

local function candidate_is_valid(candidate)
    if not candidate or not candidate.snapshot then
        return false
    end
    local bufnr = candidate.snapshot.bufnr
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    return get_buffer_version(bufnr) == candidate.snapshot.version
end

local function notify_did_show(candidate)
    if candidate.shown then
        return
    end

    local client = vim.lsp.get_client_by_id(candidate.client_id)
    if not client then
        return
    end

    client:notify("textDocument/didShowInlineEdit", {
        item = {
            command = candidate.edit.command,
        },
    })
    candidate.shown = true
end

local function render_candidate(bufnr)
    local candidate = M._candidates[bufnr]
    if not candidate or M._suppressed then
        return false
    end
    if vim.api.nvim_get_current_buf() ~= bufnr then
        return false
    end
    if vim.api.nvim_get_mode().mode ~= "n" then
        return false
    end
    if not candidate_is_valid(candidate) then
        invalidate_candidate(bufnr)
        return false
    end

    local displayed = nes_ui._display_next_suggestion(bufnr, nes_ns, { candidate.edit })
    if displayed then
        notify_did_show(candidate)
    end
    return displayed
end

local function buffer_has_inflight(bufnr)
    for _, state in pairs(M._clients) do
        if state.inflight and state.inflight.snapshot and state.inflight.snapshot.bufnr == bufnr then
            return true
        end
    end
    return false
end

local function flush_pending(client)
    local state = get_client_state(client.id)
    if state.inflight or not state.pending then
        return
    end

    local pending = state.pending
    state.pending = nil

    local snapshot = pending.snapshot
    if not snapshot or not vim.api.nvim_buf_is_valid(snapshot.bufnr) then
        return
    end
    if not client.attached_buffers[snapshot.bufnr] then
        return
    end
    if not pending.force and M._last_requested[snapshot.bufnr] == snapshot.fingerprint then
        return
    end

    local candidate = M._candidates[snapshot.bufnr]
    if candidate and candidate.snapshot and candidate.snapshot.fingerprint ~= snapshot.fingerprint then
        invalidate_candidate(snapshot.bufnr)
    end

    local seq = (M._latest_seq[client.id] or 0) + 1
    M._latest_seq[client.id] = seq
    M._last_requested[snapshot.bufnr] = snapshot.fingerprint

    local ok, req_id = client:request(
        "textDocument/copilotInlineEdit",
        snapshot.params,
        function(err, result, ctx)
            local client_state = get_client_state(ctx.client_id)
            if client_state.inflight and client_state.inflight.request_id == ctx.request_id then
                client_state.inflight = nil
                redraw_ruler()
            end

            local next_client = vim.lsp.get_client_by_id(ctx.client_id)

            if M._latest_seq[ctx.client_id] ~= seq then
                if next_client then
                    flush_pending(next_client)
                end
                return
            end

            if err then
                local cancelled = err.code == -32800
                    or (err.message and err.message:lower():find("cancel"))
                if not cancelled then
                    vim.notify("[copilot-lsp] " .. err.message)
                end
                if next_client then
                    flush_pending(next_client)
                end
                return
            end

            if not vim.api.nvim_buf_is_valid(snapshot.bufnr) then
                if next_client then
                    flush_pending(next_client)
                end
                return
            end

            if get_buffer_version(snapshot.bufnr) ~= snapshot.version then
                if next_client then
                    flush_pending(next_client)
                end
                return
            end

            if not result or not result.edits or #result.edits == 0 then
                invalidate_candidate(snapshot.bufnr)
                if next_client then
                    flush_pending(next_client)
                end
                return
            end

            local edit = result.edits[1]
            edit.newText = edit.text

            M._candidates[snapshot.bufnr] = {
                edit = edit,
                client_id = ctx.client_id,
                snapshot = snapshot,
                shown = false,
            }
            redraw_ruler()
            render_candidate(snapshot.bufnr)

            if next_client then
                flush_pending(next_client)
            end
        end
    )

    if ok and req_id then
        state.inflight = {
            request_id = req_id,
            seq = seq,
            snapshot = snapshot,
        }
        redraw_ruler()
    else
        redraw_ruler()
    end
end

local function enqueue_snapshot(client, snapshot, opts)
    local state = get_client_state(client.id)
    local force = opts and opts.force_request == true or false

    if not force then
        if state.pending and state.pending.snapshot
            and state.pending.snapshot.fingerprint == snapshot.fingerprint then
            return
        end
        if state.inflight and state.inflight.snapshot
            and state.inflight.snapshot.fingerprint == snapshot.fingerprint then
            return
        end
        if M._last_requested[snapshot.bufnr] == snapshot.fingerprint then
            return
        end
    end

    state.pending = {
        snapshot = snapshot,
        force = force,
    }

    if state.inflight and state.inflight.request_id then
        client:cancel_request(state.inflight.request_id)
        state.inflight = nil
    end

    flush_pending(client)
end

local function get_display_state(bufnr)
    return vim.b[bufnr].nes_state
end

local function get_start_byte_col(bufnr, state)
    local start_line = state.range.start.line
    local start_char = state.range.start.character
    local line_text = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + 1, false)[1] or ""
    return vim.str_byteindex(line_text, "utf-16", start_char, false)
end

local function get_applied_end_cursor(bufnr, state)
    local start_line = state.range.start.line
    local start_byte_col = get_start_byte_col(bufnr, state)
    local new_text = state.newText or state.text or ""
    local new_lines = vim.split(new_text, "\n", { plain = true, trimempty = false })

    if #new_lines <= 1 then
        return start_line + 1, start_byte_col + #(new_lines[1] or "")
    end

    return start_line + #new_lines, #(new_lines[#new_lines] or "")
end

local function cleanup_buffer(bufnr)
    invalidate_candidate(bufnr)
    M._last_requested[bufnr] = nil
    M._insert_changed[bufnr] = nil

    for client_id, state in pairs(M._clients) do
        if state.pending and state.pending.snapshot and state.pending.snapshot.bufnr == bufnr then
            state.pending = nil
        end
        if state.inflight and state.inflight.snapshot and state.inflight.snapshot.bufnr == bufnr then
            local client = vim.lsp.get_client_by_id(client_id)
            if client then
                client:cancel_request(state.inflight.request_id)
            end
            state.inflight = nil
        end
        if not state.pending and not state.inflight then
            M._clients[client_id] = nil
        end
    end
end

function M.suppress()
    M._suppressed = true
    dismiss_view(vim.api.nvim_get_current_buf())
end

function M.unsuppress()
    M._suppressed = false
    render_candidate(vim.api.nvim_get_current_buf())
    redraw_ruler()
end

--- Cancel any in-flight NES request for all tracked clients.
function M.cancel()
    for client_id, state in pairs(M._clients) do
        if state.inflight and state.inflight.request_id then
            local client = vim.lsp.get_client_by_id(client_id)
            if client then
                client:cancel_request(state.inflight.request_id)
            end
        end
        state.inflight = nil
        state.pending = nil
    end
    redraw_ruler()
end

---@param bufnr? integer
---@return { state: string, candidate: boolean, shown?: boolean, suppressed: boolean }
function M.get_status(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()

    local candidate = M._candidates[bufnr]
    local ready = candidate ~= nil and candidate_is_valid(candidate)

    if buffer_has_inflight(bufnr) then
        return {
            state = "requesting",
            candidate = ready,
            shown = ready and candidate.shown or false,
            suppressed = M._suppressed,
        }
    end

    if ready then
        return {
            state = "ready",
            candidate = true,
            shown = candidate.shown,
            suppressed = M._suppressed,
        }
    end

    return {
        state = "idle",
        candidate = false,
        suppressed = M._suppressed,
    }
end

--- Requests the NextEditSuggestion from the current cursor position.
---@param copilot_lss? vim.lsp.Client|string
---@param opts? { force_request?: boolean }
function M.request_nes(copilot_lss, opts)
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.api.nvim_get_mode().mode ~= "n" then
        return
    end
    if type(copilot_lss) == "string" then
        copilot_lss = vim.lsp.get_clients({ name = copilot_lss })[1]
    end
    assert(copilot_lss, errs.ErrNotStarted)
    if not copilot_lss.attached_buffers[bufnr] then
        return
    end

    local snapshot = capture_snapshot(bufnr)
    if not snapshot then
        return
    end

    enqueue_snapshot(copilot_lss, snapshot, opts)
end

--- Walks the cursor to the start of the edit.
--- This function returns false if there is no edit to apply or if the cursor is already at the start position of the
--- edit.
---@param bufnr? integer
---@return boolean --if the cursor walked
function M.walk_cursor_start_edit(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    ---@type copilotlsp.InlineEdit
    local state = get_display_state(bufnr)
    if not state then
        return false
    end

    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local cursor_row, cursor_col = unpack(vim.api.nvim_win_get_cursor(0))
    local start_line = state.range.start.line
    local start_char = state.range.start.character
    if state.range.start.line >= total_lines then
        if cursor_row == total_lines then
            return false
        end
        vim.lsp.util.show_document({
            uri = state.textDocument.uri,
            range = {
                start = { line = total_lines - 1, character = 0 },
                ["end"] = { line = total_lines - 1, character = 0 },
            },
        }, "utf-16", { focus = true })
        return true
    end

    local start_byte_col = get_start_byte_col(bufnr, state)
    if cursor_row - 1 == start_line and cursor_col == start_byte_col then
        return false
    end

    vim.b[bufnr].nes_jump = true
    if vim.api.nvim_get_current_buf() ~= vim.uri_to_bufnr(state.textDocument.uri) then
        vim.b[bufnr].nes_jump = false
        return false
    end

    vim.schedule(function()
        if vim.api.nvim_get_current_buf() ~= bufnr then
            return
        end
        vim.api.nvim_win_set_cursor(0, { start_line + 1, start_byte_col })
    end)
    return true
end

--- Walks the cursor to the end of the edit.
--- This function returns false if there is no edit to apply or if the cursor is already at the end position of the
--- edit.
---@param bufnr? integer
---@return boolean --if the cursor walked
function M.walk_cursor_end_edit(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    ---@type copilotlsp.InlineEdit
    local state = get_display_state(bufnr)
    if not state then
        return false
    end
    local target_row, target_col = get_applied_end_cursor(bufnr, state)
    vim.schedule(function()
        if vim.api.nvim_get_current_buf() ~= bufnr then
            return
        end

        local line_count = vim.api.nvim_buf_line_count(bufnr)
        target_row = math.max(1, math.min(target_row, line_count))
        local line_text = vim.api.nvim_buf_get_lines(bufnr, target_row - 1, target_row, false)[1] or ""
        target_col = math.max(0, math.min(target_col, #line_text))
        pcall(vim.api.nvim_win_set_cursor, 0, { target_row, target_col })
    end)
    return true
end

--- Apply the currently displayed NES edit.
---@param bufnr? integer
---@return boolean --if the nes was applied
function M.apply_pending_nes(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()

    ---@type copilotlsp.InlineEdit
    local state = get_display_state(bufnr)
    if not state then
        return false
    end

    vim.schedule(function()
        utils.apply_inline_edit(state)
        local client = get_copilot_client(bufnr)
        if client and state.command then
            client:exec_cmd(state.command, { bufnr = bufnr })
        end
        vim.b[bufnr].nes_jump = false
        invalidate_candidate(bufnr)
        if client then
            vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
                    M.request_nes(client, { force_request = true })
                end
            end)
        end
    end)
    return true
end

---@param bufnr? integer
function M.clear_suggestion(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    dismiss_view(bufnr)
end

--- Clear the current suggestion and discard the cached candidate.
---@param bufnr? integer
---@return boolean
function M.clear(bufnr)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    local had_candidate = M._candidates[bufnr] ~= nil or vim.b[bufnr].nes_state ~= nil
    invalidate_candidate(bufnr)
    return had_candidate
end

--- Clear the current suggestion and immediately request a new one (no debounce).
---@param copilot_lss vim.lsp.Client|string
function M.reject_and_next(copilot_lss)
    M.clear()
    M.request_nes(copilot_lss, { force_request = true })
end

---@param client vim.lsp.Client
---@param au integer
function M.lsp_on_init(client, au)
    local cfg = require("copilot-lsp.config").config
    local debounced_request = utils.debounce(function()
        M.request_nes(client)
    end, cfg.nes.debounce)
    local debounced_focus = utils.debounce(function()
        local td_params = vim.lsp.util.make_text_document_params()
        client:notify("textDocument/didFocus", {
            textDocument = {
                uri = td_params.uri,
            },
        })
    end, 10)

    local trigger_evts = {}
    local trigger_patterns = {}
    for _, ev in ipairs(cfg.nes.trigger.events) do
        local evt, pat = ev:match("^(%S+)%s*(.*)")
        table.insert(trigger_evts, evt)
        table.insert(trigger_patterns, pat ~= "" and pat or nil)
    end

    for i, evt in ipairs(trigger_evts) do
        local pattern = trigger_patterns[i]
        local autocmd_opts = {
            callback = function(args)
                if evt == "ModeChanged" and pattern == "i:n" then
                    if not M._insert_changed[args.buf] then
                        return
                    end
                    M._insert_changed[args.buf] = false
                end
                debounced_request()
            end,
            group = au,
        }
        if pattern then
            autocmd_opts.pattern = pattern
        end
        vim.api.nvim_create_autocmd(evt, autocmd_opts)
    end

    vim.api.nvim_create_autocmd("InsertEnter", {
        callback = function(args)
            M._insert_changed[args.buf] = false
        end,
        group = au,
    })

    vim.api.nvim_create_autocmd("TextChangedI", {
        callback = function(args)
            M._insert_changed[args.buf] = true
        end,
        group = au,
    })

    vim.api.nvim_create_autocmd(cfg.nes.clear.events, {
        callback = function(args)
            M.clear(args.buf)
        end,
        group = au,
    })

    if cfg.nes.clear.esc then
        vim.on_key(function(_, typed)
            if typed == "\27" then
                vim.schedule(function()
                    M.clear()
                end)
            end
        end, nes_ns)
    end

    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        callback = function()
            debounced_focus()
            if not M._suppressed then
                render_candidate(vim.api.nvim_get_current_buf())
            end
        end,
        group = au,
    })

    vim.api.nvim_create_autocmd("BufDelete", {
        callback = function(args)
            cleanup_buffer(args.buf)
        end,
        group = au,
    })
end

return M
