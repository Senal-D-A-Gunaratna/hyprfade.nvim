local health = vim.health or require("health")

local function find_terminal_pid(term_names)
	local pid = vim.uv.os_getppid() --[[@as integer]]
	local max_hops = 25

	for _ = 1, max_hops do
		local status_file = "/proc/" .. pid .. "/status"
		local ok, lines = pcall(vim.fn.readfile, status_file)
		if not ok or not lines then
			break
		end

		local name = nil
		local ppid = nil
		for _, line in ipairs(lines) do
			if line:match("^Name:") then
				name = line:match("^Name:%s+(.+)$")
			elseif line:match("^PPid:") then
				ppid = tonumber(line:match("^PPid:%s+(%d+)$"))
			end
		end

		if name then
			for _, term_name in ipairs(term_names) do
				if name == term_name then
					return pid, name
				end
			end
		end

		if ppid and ppid > 1 then
			pid = ppid
		else
			break
		end
	end

	return nil, nil
end

-- Mirrors hyprfade/init.lua's fallback resolution: queries the Hyprland IPC
-- for the focused window and only honours it when the class matches a
-- configured terminal name. Returns (nil, class) when the query succeeds but
-- the class doesn't match, so health can explain why the fallback would no-op.
---@param term_names string[]
---@return string|nil, string|nil selector ("address:0x..."), focused class
local function find_active_window(term_names)
	local out = vim.fn.system({ "hyprctl", "activewindow", "-j" })
	if vim.v.shell_error ~= 0 or type(out) ~= "string" or out == "null" then
		return nil, nil
	end
	local ok, win = pcall(vim.json.decode, out)
	if not ok or type(win) ~= "table" then
		return nil, nil
	end
	local class = win.class or win.initialClass
	if type(class) ~= "string" or class == "" then
		return nil, nil
	end
	if type(win.address) ~= "string" or win.address == "" then
		return nil, class
	end
	for _, term_name in ipairs(term_names) do
		if class == term_name then
			return ("address:%s"):format(win.address), class
		end
	end
	return nil, class
end

local M = {}

function M.check()
	health.start("hyprfade")

	local term_names = vim.g.hyprfade_opts and vim.g.hyprfade_opts.term_names

	health.info(string.format("Terminals: %s", vim.inspect(term_names)))

	if vim.fn.executable("hyprctl") == 0 then
		health.error(
			"`hyprctl` not found on PATH",
			{ "Install Hyprland or add hyprctl to your PATH" }
		)
		return
	end
	health.ok("`hyprctl` is available")

	local hyprland_sig = vim.fn.environ()["HYPRLAND_INSTANCE_SIGNATURE"]
	if not hyprland_sig or hyprland_sig == "" then
		health.warn("`$HYPRLAND_INSTANCE_SIGNATURE` is not set", {
			"Hyprland may not be running",
			"Health checks beyond `hyprctl` availability will be limited",
		})
	else
		local runtime_dir = vim.fn.environ()["XDG_RUNTIME_DIR"] or ("/run/user/" .. vim.fn.getuid())
		local instance_dir = runtime_dir .. "/hypr/" .. hyprland_sig
		if vim.fn.isdirectory(instance_dir) == 1 then
			health.ok("Hyprland instance detected")
		else
			health.warn(
				string.format("Hyprland instance directory (%s) not found", instance_dir),
				{ "Health checks beyond `hyprctl` availability will be limited" }
			)
		end
	end

	local pid, name
	if term_names then
		pid, name = find_terminal_pid(term_names)
	end
	if pid then
		health.ok(string.format("Terminal detected: %s (PID %d)", name, pid))
	else
		health.warn("Could not locate a supported terminal in the process tree", {
			"hyprfade will fall back to the focused window if its class matches `term_names`",
			"Opacity won't be applied if the focused window isn't a known terminal",
		})
	end

	if term_names then
		local selector, class = find_active_window(term_names)
		if selector then
			health.ok(string.format("Active-window fallback available: %s (%s)", class, selector))
		elseif class then
			health.warn(
				string.format("The focused window (%s) is not a configured terminal", class),
				{
					"The active-window fallback won't match it if PID resolution fails",
				}
			)
		else
			health.warn("Could not query the active window via `hyprctl activewindow -j`", {
				"The active-window fallback will be unavailable if PID resolution fails",
			})
		end

		local using_fallback = vim.g.hyprfade_used_fallback
		if using_fallback ~= nil then
			if using_fallback then
				health.info(
					"Currently using the active-window fallback (terminal PID wasn't resolvable)"
				)
			else
				health.info("Currently using /proc PID detection to target the terminal window")
			end
		end
	end
end

return M
