local health = vim.health or require("health")

local function find_terminal_pid(term_names)
	local pid = vim.fn.getpid()
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

local function find_active_window()
	local out = vim.fn.system({ "hyprctl", "activewindow", "-j" })
	if vim.v.shell_error ~= 0 or type(out) ~= "string" or out == "null" then
		return nil, nil
	end
	local ok, win = pcall(vim.json.decode, out)
	if not ok or type(win) ~= "table" then
		return nil, nil
	end
	local class = win.class or win.initialClass
	if
		type(class) ~= "string"
		or class == ""
		or type(win.address) ~= "string"
		or win.address == ""
	then
		return nil, nil
	end
	return win.address, class
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
		local instance_dir = (
			vim.fn.environ()["XDG_RUNTIME_DIR"] or "/run/user/" .. vim.fn.getuid()
		)
			.. "/hypr/"
			.. hyprland_sig
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
			"hyprfade will still work when called manually with a specific opacity",
			"Only HyprfadeToggle and HyprfadeReset auto-detection will be affected",
		})
	end

	local addr, class = find_active_window()
	if not addr then
		health.warn("Could not query the active window via `hyprctl activewindow -j`", {
			"The active-window fallback will be unavailable if PID resolution fails",
		})
	else
		local is_term = term_names and vim.tbl_contains(term_names, class) or false
		if is_term then
			health.ok(string.format("Active-window fallback available: %s (%s)", class, addr))
		else
			health.warn(
				string.format("The focused window (%s) is not a configured terminal", class),
				{
					"The active-window fallback won't match it if PID resolution fails",
				}
			)
		end
	end
end

return M
