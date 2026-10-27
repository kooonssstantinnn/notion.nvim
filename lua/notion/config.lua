local M = {}

---@class NotionConfig
M.defaults = {
	-- Integration token. String, or a function returning one (e.g. reading a password manager).
	-- Overrides the folder login (`:Notion login`), which overrides $NOTION_TOKEN.
	token = nil,
	token_env = "NOTION_TOKEN",
	-- Where synced pages are stored as markdown files. String or function.
	-- Default: `notion/` in the project root (git root of the cwd, else the cwd).
	sync_dir = function()
		local cwd = vim.fn.getcwd()
		return (vim.fs.root(cwd, ".git") or cwd) .. "/notion"
	end,
	-- Page ID/URL new pages are created under. When nil you are asked on first publish.
	default_parent = nil,
	-- Ask for confirmation before pushing changes to Notion.
	confirm_publish = true,
	-- Remind once per buffer that :w only saves locally.
	notify_on_save = true,
	-- Run :Notion sync in the background on startup.
	sync_on_startup = false,
	-- Optional predicate `fun(page): boolean` to choose which pages get synced.
	filter = nil,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---Resolved sync directory (re-evaluated on each call, so it follows :cd).
function M.sync_dir()
	local dir = M.options.sync_dir
	if type(dir) == "function" then
		dir = dir()
	end
	return vim.fs.normalize(dir)
end

-- Logins are stored per folder (keyed by the resolved sync_dir) outside the project,
-- so a token can't be committed by accident.
function M.auth_file()
	return vim.fn.stdpath("state") .. "/notion/auth.json"
end

-- Single token written by older versions of :Notion login.
function M.legacy_token_file()
	return vim.fn.stdpath("state") .. "/notion/token"
end

local function read_auth()
	local f = io.open(M.auth_file(), "r")
	if not f then
		return {}
	end
	local ok, data = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
	f:close()
	return ok and type(data) == "table" and data or {}
end

local function write_auth(data)
	local path = M.auth_file()
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local f = assert(io.open(path, "w"))
	f:write(vim.json.encode(data))
	f:close()
	vim.uv.fs_chmod(path, 384) -- 0600
end

---Login saved for a folder (default: the current sync_dir).
---@return { token: string, name: string?, workspace: string? }?
function M.folder_auth(dir)
	dir = dir or M.sync_dir()
	local data = read_auth()
	if not data[dir] then
		-- Migrate an old global login to the first folder that needs one.
		local f = io.open(M.legacy_token_file(), "r")
		if f then
			local token = vim.trim(f:read("*a") or "")
			f:close()
			os.remove(M.legacy_token_file())
			if token ~= "" and next(data) == nil then
				data[dir] = { token = token }
				write_auth(data)
			end
		end
	end
	return data[dir]
end

function M.save_folder_auth(auth, dir)
	local data = read_auth()
	data[dir or M.sync_dir()] = auth
	write_auth(data)
end

function M.remove_folder_auth(dir)
	local data = read_auth()
	data[dir or M.sync_dir()] = nil
	write_auth(data)
end

---Token for the current folder: `token` option > folder login > $NOTION_TOKEN.
---@return string?
function M.token()
	local t = M.options.token
	if type(t) == "function" then
		t = t()
	end
	if type(t) == "string" and t ~= "" then
		return vim.trim(t)
	end
	local auth = M.folder_auth()
	if auth and auth.token and auth.token ~= "" then
		return auth.token
	end
	local env = M.options.token_env and vim.env[M.options.token_env]
	if env and env ~= "" then
		return vim.trim(env)
	end
end

return M
