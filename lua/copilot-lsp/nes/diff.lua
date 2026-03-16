local M = {}

local config = require("copilot-lsp.config").config
local util = require("copilot-lsp.util")

--- Tokenize a string into words or chars based on config
---@param str string
---@return string[]
local function tokenize(str)
    if config.nes.diff.inline == "chars" then
        return util.split_chars(str)
    end
    return util.split_words(str)
end

--- Build inline extmarks for a single line pair using token-level diff.
--- Returns nil if the insert ratio is too high (fall back to block diff).
---@param old_line string
---@param new_line string
---@param row integer 0-indexed row in buffer
---@param line_offset integer byte offset of old_line start in buffer (col)
---@return { line: integer, col: integer, opts: vim.api.keyset.set_extmark }[]|nil
local function inline_diff_line(old_line, new_line, row, line_offset)
    local old_tokens = tokenize(old_line)
    local new_tokens = tokenize(new_line)

    -- Build strings joined by NUL for vim.diff
    local old_str = table.concat(old_tokens, "\n") .. "\n"
    local new_str = table.concat(new_tokens, "\n") .. "\n"

    local hunks = vim.diff(old_str, new_str, { algorithm = "minimal", result_type = "indices" })
    if not hunks then
        return nil
    end

    -- Count total inserted tokens to compute insert ratio
    local total_new = #new_tokens
    local inserted = 0
    for _, h in ipairs(hunks) do
        inserted = inserted + h[4] -- b_count
    end
    if total_new > 0 and inserted / total_new >= 0.5 then
        return nil -- too many insertions, fall back to block
    end

    -- Map token index -> byte col in the original line
    local function token_cols(tokens)
        local cols = {}
        local col = line_offset
        for _, tok in ipairs(tokens) do
            table.insert(cols, col)
            col = col + #tok
        end
        table.insert(cols, col) -- sentinel (end col)
        return cols
    end

    local old_cols = token_cols(old_tokens)
    local new_cols = token_cols(new_tokens)

    local extmarks = {}

    -- Track which old tokens are deleted and new tokens are inserted
    local old_deleted = {} -- set of 1-based indices
    local new_inserted = {} -- set of 1-based indices
    for _, h in ipairs(hunks) do
        local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
        for i = a_start, a_start + a_count - 1 do
            old_deleted[i] = true
        end
        for i = b_start, b_start + b_count - 1 do
            new_inserted[i] = true
        end
    end

    -- Emit deletion extmarks for contiguous runs of deleted old tokens
    local del_start = nil
    for i = 1, #old_tokens + 1 do
        if old_deleted[i] then
            if not del_start then
                del_start = i
            end
        else
            if del_start then
                table.insert(extmarks, {
                    line = row,
                    col = old_cols[del_start],
                    opts = {
                        hl_group = "CopilotLspNesDelete",
                        end_row = row,
                        end_col = old_cols[i],
                    },
                })
                del_start = nil
            end
        end
    end

    -- Emit insertion extmarks for contiguous runs of inserted new tokens
    -- We anchor each insertion at the position of the last non-inserted old token before it
    -- Map: for each insertion run, find the preceding old token's end col
    -- We need to match hunk positions: for each hunk, deletions are at a_start and insertions at b_start
    for _, h in ipairs(hunks) do
        local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
        if b_count > 0 then
            -- anchor col: end of the last old token before this hunk's deletion start
            local anchor_col
            if a_start > 1 then
                anchor_col = old_cols[a_start] -- start of first deleted token (= end of previous)
            else
                anchor_col = line_offset
            end
            -- If there are deletions too, anchor after where they were
            if a_count > 0 then
                anchor_col = old_cols[a_start] -- extmark sits at deletion start
            end

            local ins_text = {}
            for i = b_start, b_start + b_count - 1 do
                table.insert(ins_text, new_tokens[i])
            end
            table.insert(extmarks, {
                line = row,
                col = anchor_col,
                opts = {
                    virt_text = { { table.concat(ins_text), "CopilotLspNesAdd" } },
                    virt_text_pos = "inline",
                },
            })
        end
    end

    return extmarks
end

--- Compute extmarks for a block-level diff (full lines).
---@param bufnr integer
---@param old_lines string[]
---@param new_lines string[]
---@param start_row integer 0-indexed start row of old_lines in buffer
---@param end_row integer 0-indexed end row (inclusive)
---@param ns_id integer (unused here, just for signature compat)
---@param filetype string
---@return { line: integer, col: integer, opts: vim.api.keyset.set_extmark }[]
local function block_diff(bufnr, old_lines, new_lines, start_row, end_row, filetype)
    local extmarks = {}

    -- Deletion: highlight entire old range
    if #old_lines > 0 then
        local last_old = old_lines[#old_lines]
        table.insert(extmarks, {
            line = start_row,
            col = 0,
            opts = {
                hl_group = "CopilotLspNesDelete",
                end_row = start_row + #old_lines - 1,
                end_col = #last_old,
            },
        })
    end

    -- Insertion: virt_lines after end_row
    if #new_lines > 0 then
        local ins_text = table.concat(new_lines, "\n")
        local virt_lines = util.hl_text_to_virt_lines(ins_text, filetype)
        local anchor = math.min(end_row, vim.api.nvim_buf_line_count(bufnr) - 1)
        table.insert(extmarks, {
            line = anchor,
            col = 0,
            opts = {
                virt_lines = virt_lines,
                strict = false,
            },
        })
    end

    return extmarks
end

--- Compute extmarks for a single LSP TextEdit against a buffer.
---@param bufnr integer
---@param edit lsp.TextEdit
---@param filetype string
---@return { line: integer, col: integer, opts: vim.api.keyset.set_extmark }[]
function M.compute(bufnr, edit, filetype)
    local range = edit.range
    local new_text = edit.newText or ""
    local start_line = range.start.line
    local start_char = range.start.character
    local end_line = range["end"].line
    local end_char = range["end"].character

    local old_lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
    local new_lines = vim.split(new_text, "\n", { plain = true })

    -- Apply character-level boundaries to get the actual old/new text segments
    -- old_text is the exact characters being replaced
    local function build_old_text()
        if #old_lines == 0 then
            return ""
        end
        local lines = vim.deepcopy(old_lines)
        -- trim end of last line
        lines[#lines] = lines[#lines]:sub(1, end_char)
        -- trim start of first line
        lines[1] = lines[1]:sub(start_char + 1)
        return table.concat(lines, "\n")
    end

    local old_text = build_old_text()

    -- No change
    if old_text == new_text then
        return {}
    end

    local extmarks = {}
    local inline_mode = config.nes.diff.inline

    -- Run line-level diff to find hunks
    local old_str = old_text ~= "" and (old_text .. "\n") or ""
    local new_str = new_text ~= "" and (new_text .. "\n") or ""
    local hunks = vim.diff(old_str, new_str, { algorithm = "patience", result_type = "indices" })

    if not hunks or #hunks == 0 then
        return {}
    end

    local old_text_lines = vim.split(old_text, "\n", { plain = true })
    local new_text_lines = vim.split(new_text, "\n", { plain = true })

    for _, h in ipairs(hunks) do
        local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]

        -- Convert to 0-indexed rows in the buffer
        local hunk_start_row = start_line + (a_start - 1)
        local hunk_end_row = hunk_start_row + math.max(a_count - 1, 0)

        local hunk_old = {}
        for i = a_start, a_start + a_count - 1 do
            table.insert(hunk_old, old_text_lines[i] or "")
        end
        local hunk_new = {}
        for i = b_start, b_start + b_count - 1 do
            table.insert(hunk_new, new_text_lines[i] or "")
        end

        -- Decide: inline or block?
        local use_inline = inline_mode
            and a_count == b_count
            and a_count <= 3
            and a_count > 0

        if use_inline then
            -- Try inline diff for each line pair
            local all_inline = {}
            local failed = false
            for i = 1, a_count do
                local row = hunk_start_row + (i - 1)
                -- col offset: first line uses start_char, subsequent lines start at 0
                local col_off = (i == 1 and a_start == 1) and start_char or 0
                local result = inline_diff_line(hunk_old[i], hunk_new[i], row, col_off)
                if not result then
                    failed = true
                    break
                end
                for _, ext in ipairs(result) do
                    table.insert(all_inline, ext)
                end
            end
            if not failed then
                for _, ext in ipairs(all_inline) do
                    table.insert(extmarks, ext)
                end
            else
                -- Fall back to block
                local blk = block_diff(bufnr, hunk_old, hunk_new, hunk_start_row, hunk_end_row, filetype)
                for _, ext in ipairs(blk) do
                    table.insert(extmarks, ext)
                end
            end
        else
            local blk = block_diff(bufnr, hunk_old, hunk_new, hunk_start_row, hunk_end_row, filetype)
            for _, ext in ipairs(blk) do
                table.insert(extmarks, ext)
            end
        end
    end

    return extmarks
end

return M
