---@class hyprfade
local M = {}

---@class hyprfadeOpts
---@field opacity number
---@field opacity_inactive? number
---@field term_names string[]
local opts = {}

local current = nil
local terminal_pid = nil ---@type integer|nil|?

---@param msg string
local function warn(msg)
    vim.notify("hyprfade: " .. msg, vim.log.levels.WARN)
end

---@return integer|nil|? pid
local function find_terminal_pid()
    if terminal_pid then
        return terminal_pid
    end

    local pid = vim.uv.os_getppid() --[[@as integer]]
    local max_hops = 25
    for _ = 1, max_hops do
        local status_file = vim.fs.joinpath("/proc", tostring(pid), "status")
        local ok, lines = pcall(vim.fn.readfile, status_file) ---@type boolean, string[]|nil|?
        if ok and lines then
            local name, ppid = nil, nil ---@type string|nil|?, integer|nil|?
            for _, line in ipairs(lines) do
                if line:match("^Name:") then
                    name = line:match("^Name:%s+.+$") --[[@as string|nil|?]]
                elseif line:match("^PPid:") then
                    ppid = tonumber(line:match("^PPid:%s+(%d+)$"), 10)
                end
            end

            if name then
                for _, term_name in ipairs(opts.term_names) do
                    if name == term_name or name:find(term_name) then
                        terminal_pid = pid
                        return pid
                    end
                end
            end

            if not ppid or ppid <= 1 then
                break
            end
            pid = ppid
        end
    end
end

---@param prop string
---@param val number
---@param pid integer
local function set_prop(prop, val, pid)
    return ('hl.dispatch(hl.dsp.window.set_prop({ prop = "%s", value = %s, window = "%s" }))'):format(
        prop,
        tostring(val),
        ("pid:%d"):format(pid)
    )
end

-- Hyprland 0.55 (May 2026) replaced the classic `hyprctl dispatch <name>
-- <args...>` calling convention with a Lua expression API: `hyprctl
-- dispatch` now wraps its argument as `hl.dispatch(<your text>)` and runs
-- it through the Lua VM, so old space-separated args like
-- `dispatch setprop pid:X opacity 0.5` are rejected outright with a Lua
-- syntax error. This affects every dispatcher, not just setprop.
-- Ref: https://github.com/hyprwm/Hyprland/discussions/14255
--
-- The confirmed working form (from the Hyprland forum and the Window
-- Rules wiki page's own set_prop examples) is a typed table:
--   hl.dsp.window.set_prop({ prop = "...", value = ..., window = "..." })
--
-- `hyprctl eval '<lua>'` runs one or more semicolon-separated Lua
-- statements in a single round trip, so we chain all the set_prop calls
-- needed (override flag + value, for both active and inactive) into one
-- eval instead of several separate hyprctl invocations.
---@param value number
---@param inactive_value? number
local function set_opacity(value, inactive_value)
    inactive_value = inactive_value or value
    if vim.fn.executable("hyprctl") == 0 then
        warn("hyprctl not found on PATH")
        return
    end

    local pid = find_terminal_pid()
    if not pid then
        warn("could not resolve terminal PID")
        return
    end

    local statements = {
        set_prop("opacity_override", 1, pid),
        set_prop("opacity", value, pid),
        set_prop("opacity_inactive_override", 1, pid),
        set_prop("opacity_inactive", inactive_value, pid),
    }

    vim.system({ "hyprctl", "eval", table.concat(statements, "; ") }, {}, function() end)
    current = value
end

local function toggle()
    if current == 1 then
        set_opacity(opts.opacity, opts.opacity_inactive)
    else
        set_opacity(1, 1)
    end
end

local function reset()
    set_opacity(1, 1)
end

---@param user_opts hyprfadeOpts
function M.setup(user_opts)
    if not user_opts or type(user_opts) ~= "table" then
        vim.notify(
            "hyprfade: opts table is required, see https://github.com/andrewferrier/hyprfade.nvim",
            vim.log.levels.ERROR
        )
        return
    end
    opts = vim.deepcopy(user_opts)
    if type(opts.opacity) ~= "number" or opts.opacity < 0 or opts.opacity > 1 then
        vim.notify("hyprfade: opts.opacity must be a number between 1 and 0", vim.log.levels.ERROR)
        return
    end
    if opts.opacity_inactive == nil then
        opts.opacity_inactive = opts.opacity
    elseif type(opts.opacity_inactive) ~= "number" or opts.opacity_inactive < 0 or opts.opacity_inactive > 1 then
        vim.notify("hyprfade: opts.opacity_inactive must be a number between 1 and 0", vim.log.levels.ERROR)
        return
    end
    if type(opts.term_names) ~= "table" or #opts.term_names == 0 then
        vim.notify(
            "hyprfade: opts.term_names must be a non-empty table of terminal process names",
            vim.log.levels.ERROR
        )
        return
    end
    current = nil
    terminal_pid = nil

    vim.api.nvim_create_user_command("Hyprfade", function(input)
        local val = tonumber(input.args)
        if val then
            set_opacity(val)
        else
            vim.notify("hyprfade: usage Hyprfade <opacity>", vim.log.levels.ERROR)
        end
    end, { nargs = 1 })

    vim.api.nvim_create_user_command("HyprfadeToggle", function()
        toggle()
    end, {})

    vim.api.nvim_create_user_command("HyprfadeReset", function()
        reset()
    end, {})

    -- NOTE: applying on setup() (rather than hooking VimEnter) matters for
    -- lazy loading: lazy.nvim's VeryLazy event fires *after* VimEnter has
    -- already completed for the session, so a VimEnter autocmd registered
    -- inside setup() would never fire. setup() being called at all (eager
    -- or lazy) is itself the "the plugin is now active" signal.
    set_opacity(opts.opacity, opts.opacity_inactive)

    local group = vim.api.nvim_create_augroup("hyprfade", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            set_opacity(1)
        end,
    })
end

return M
