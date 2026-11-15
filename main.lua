--- rclone remotes in Yazi: mount a remote, go to its mount point, and unmount it when you are done.
---
--- Keys, in keymap.toml:
---
---   { on = ["R", "m"], run = "plugin rclone mount",   desc = "Mount an rclone remote" }
---   { on = ["R", "u"], run = "plugin rclone unmount", desc = "Unmount an rclone remote" }
---   { on = ["R", "j"], run = "plugin rclone mounts",  desc = "Go to a mounted remote" }
---
--- Optional setup, in init.lua:
---
---   require("rclone"):setup {
---     mount_dir = "~/.local/state/rclone/mnt",   -- <mount_dir>/<remote>/<path>
---     cache_dir = "~/.cache/rclone",             -- <cache_dir>/<remote>/<path>
---     mount_args = { "--vfs-cache-mode", "full" },   -- instead of the defaults of the plugin
---   }

local M = {}

-- the options of setup, for the code that runs async (see get_options): async code has a Lua state of
-- its own, where `setup` has not run
local get_options = ya.sync(function(state)
	return state.options or {}
end)

local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

function M:setup(opts)
	self.options = opts or {}
end

-- what rclone is told about a mount, when `mount_args` is not set
local DEFAULT_ARGS = {
	"--vfs-cache-mode", "writes",
	"--vfs-cache-max-age", "24h",
	"--vfs-cache-max-size", "5G",
	"--dir-cache-time", "1h",
	"--poll-interval", "1m",
	"--buffer-size", "32M",
	"--umask", "002",
}

local notify = function(level, content)
	ya.notify { title = "rclone.yazi", content = content, timeout = 6, level = level }
end

local run = function(command)
	return command:stdout(Command.PIPED):stderr(Command.PIPED):output()
end

local home = os.getenv("HOME") or ""

local expand_home = function(path)
	return (path:gsub("^~", home))
end

-- a path as the user writes it, with ~ for the home folder
local pretty = function(path)
	if home ~= "" and path:sub(1, #home + 1) == home .. "/" then
		return "~" .. path:sub(#home + 1)
	end
	return path
end

local function env_or(name, fallback)
	local value = os.getenv(name)
	return (value and value ~= "") and value or fallback
end

-- The folders, from the options: the state and the cache of the user, where the user has them
local function settings(options)
	local state = env_or("XDG_STATE_HOME", home .. "/.local/state")
	local cache = env_or("XDG_CACHE_HOME", home .. "/.cache")
	return {
		mount_dir = expand_home(options.mount_dir or (state .. "/rclone/mnt")):gsub("/+$", ""),
		cache_dir = expand_home(options.cache_dir or (cache .. "/rclone")):gsub("/+$", ""),
		mount_args = options.mount_args or DEFAULT_ARGS,
	}
end

-- one entry of a menu of Yazi, a key for each: 1 to 9 and a to z
local KEYS = "123456789abcdefghijklmnopqrstuvwxyz"

local choose = function(items, label)
	local cands = {}
	for i, item in ipairs(items) do
		if i > #KEYS then
			break
		end
		cands[#cands + 1] = { on = KEYS:sub(i, i), desc = label(item) }
	end
	local index = ya.which { cands = cands }
	return index and items[index] or nil
end

-- The mounts that are under the mount directory, from the table of the system: on Linux the line is
-- `remote: on /path type fuse.rclone (...)`, and on macOS `localhost:/ on /path (nfs, ...)`
local function active_mounts(mount_dir)
	local output = run(Command("mount"))
	local list = {}
	if not output then
		return list
	end
	for line in output.stdout:gmatch("[^\n]+") do
		local path = line:match(" on (/.-) type ") or line:match(" on (/.-) %(")
		if path and (path == mount_dir or path:sub(1, #mount_dir + 1) == mount_dir .. "/") then
			list[#list + 1] = path
		end
	end
	table.sort(list)
	return list
end

local function is_mounted(mount_dir, path)
	for _, mounted in ipairs(active_mounts(mount_dir)) do
		if mounted == path then
			return true
		end
	end
	return false
end

-- macOS mounts through NFS, which needs no kernel extension, and Linux through FUSE
local function mount_command()
	local output = run(Command("uname"))
	if output and output.stdout:match("Darwin") then
		return "nfsmount"
	end
	return "mount"
end

local go_to = function(path)
	ya.emit("cd", { Url(path), raw = true })
end

local function mount(options)
	local conf = settings(options)

	local listed = run(Command("rclone"):arg("listremotes"))
	if not listed or not listed.status.success then
		return notify("error", "Cannot list the remotes: " .. (listed and listed.stderr:gsub("%s+", " ") or "`rclone` was not found"))
	end
	local remotes = {}
	for line in listed.stdout:gmatch("[^\n]+") do
		remotes[#remotes + 1] = line
	end
	if #remotes == 0 then
		return notify("warn", "rclone has no remote: set one up with `rclone config`")
	end

	local remote = choose(remotes, function(item)
		return item
	end)
	if not remote then
		return -- cancelled
	end

	local value, event = ya.input {
		pos = { "top-center", y = 2, w = 50 },
		title = "Path in " .. remote .. " (empty for the root):",
	}
	if event ~= 1 then
		return -- cancelled
	end
	local path = (value or ""):gsub("^/+", ""):gsub("/+$", "")

	local name = remote:gsub(":$", "")
	local suffix = path ~= "" and ("/" .. path) or ""
	local mount_path = conf.mount_dir .. "/" .. name .. suffix
	local cache_path = conf.cache_dir .. "/" .. name .. suffix

	if is_mounted(conf.mount_dir, mount_path) then
		return go_to(mount_path)
	end

	run(Command("mkdir"):arg { "-p", mount_path, cache_path })
	notify("info", "Mounting " .. remote .. path .. " …")

	local args = { mount_command(), remote .. path, mount_path, "--daemon", "--cache-dir", cache_path }
	for _, arg in ipairs(conf.mount_args) do
		args[#args + 1] = arg
	end
	local mounted = run(Command("rclone"):arg(args))
	if not mounted or not mounted.status.success then
		return notify("error", "Not mounted: " .. (mounted and (mounted.stderr .. mounted.stdout):gsub("%s+", " ") or "`rclone` was not found"))
	end

	notify("info", "Mounted " .. remote .. path .. " at " .. pretty(mount_path))
	go_to(mount_path)
end

local function unmount_one(conf, path)
	-- Yazi leaves the mount first: a mount that is in use cannot be unmounted
	run(Command("mkdir"):arg { "-p", conf.mount_dir })
	go_to(conf.mount_dir)
	ya.sleep(0.4)

	local result = run(Command("sh"):arg {
		"-c",
		'fusermount3 -u "$1" 2>/dev/null || fusermount -u "$1" 2>/dev/null || umount "$1"',
		"sh",
		path,
	})
	if not result or not result.status.success then
		return notify("error", "Not unmounted: " .. (result and result.stderr:gsub("%s+", " ") or ""))
	end
	notify("info", "Unmounted " .. pretty(path))
end

local function unmount(options)
	local conf = settings(options)
	local mounts = active_mounts(conf.mount_dir)
	if #mounts == 0 then
		return notify("info", "No remote is mounted under " .. pretty(conf.mount_dir))
	end

	-- the mount that Yazi is in, the deepest one, and a menu when it is in none
	local cwd = get_cwd()
	local inside
	for _, path in ipairs(mounts) do
		if cwd == path or cwd:sub(1, #path + 1) == path .. "/" then
			if not inside or #path > #inside then
				inside = path
			end
		end
	end
	local target = inside or choose(mounts, function(path)
		return path
	end)
	if not target then
		return -- cancelled
	end
	unmount_one(conf, target)
end

local function mounts_menu(options)
	local conf = settings(options)
	local mounts = active_mounts(conf.mount_dir)
	if #mounts == 0 then
		return notify("info", "No remote is mounted under " .. pretty(conf.mount_dir))
	end
	local path = choose(mounts, function(item)
		return item:sub(#conf.mount_dir + 2)
	end)
	if path then
		go_to(path)
	end
end

function M:entry(job)
	local action = job.args[1]
	local options = get_options()
	if action == "mount" then
		return mount(options)
	elseif action == "unmount" then
		return unmount(options)
	elseif action == "mounts" then
		return mounts_menu(options)
	end
	notify("error", "Use `plugin rclone mount`, `plugin rclone unmount` or `plugin rclone mounts`")
end

return M
