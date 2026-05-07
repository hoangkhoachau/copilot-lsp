local config = require("copilot-lsp.config")
local handlers = require("copilot-lsp.handlers")

---@class copilotlsp
---@field defaults copilotlsp.config
---@field config copilotlsp.config
---@field setup fun(opts?: copilotlsp.config): nil
---@field sign_out fun(client_id?: integer, bufnr?: integer): nil
local M = {}

M.defaults = config.defaults
M.config = config.config

M.sign_out = handlers.sign_out

---@param opts? copilotlsp.config configuration to merge with defaults
function M.setup(opts)
    config.setup(opts)
    M.config = config.config
end

return M
