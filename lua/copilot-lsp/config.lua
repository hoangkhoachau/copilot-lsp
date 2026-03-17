---@class copilotlsp.config.nes
---@field debounce integer Debounce delay in ms before requesting NES
---@field trigger { events: string[] }
---@field clear { events: string[], esc: boolean }
---@field diff { inline: "words"|"chars"|false }

local M = {}

---@class copilotlsp.config
---@field nes copilotlsp.config.nes
M.defaults = {
    nes = {
        debounce = 100,
        trigger = {
            events = { "ModeChanged i:n", "TextChanged" },
        },
        clear = {
            events = { "TextChangedI", "InsertEnter" },
            esc = true,
        },
        diff = {
            inline = "words", -- "words" | "chars" | false
        },
    },
}

---@type copilotlsp.config
M.config = vim.deepcopy(M.defaults)

---@param opts? copilotlsp.config configuration to merge with defaults
function M.setup(opts)
    opts = opts or {}
    M.config = vim.tbl_deep_extend("force", M.defaults, opts)
end

return M
