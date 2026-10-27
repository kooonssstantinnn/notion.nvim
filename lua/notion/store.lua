-- Local files, frontmatter and the sync index.
local config = require("notion.config")

local M = {}

local index, index_dir

local function index_path()
	return config.sync_dir() .. "/.notion-index.json"
end

-- Paths are stored relative to sync_dir on disk so the folder can be moved or committed.
function M.index()
	local dir = config.sync_dir()
	if not index or index_dir ~= dir then
		index, index_dir = { pages = {} }, dir
		local f = io.open(index_path(), "r")
		if f then
			local ok, data = pcall(vim.json.decode, f:read("*a"), { luanil = { object = true, array = true } })
			f:close()
			if ok and type(data) == "table" then
				index = data
				index.pages = index.pages or {}
				for _, e in pairs(index.pages) do
					if e.path and e.path:sub(1, 1) ~= "/" then
						e.path = dir .. "/" .. e.path
					end
				end
			end
		end
	end
	return index
end

function M.reset()
	index = nil
end

function M.save_index()
	local dir = config.sync_dir()
	local data = vim.deepcopy(M.index())
	for _, e in pairs(data.pages) do
		if e.path and vim.startswith(e.path, dir .. "/") then
			e.path = e.path:sub(#dir + 2)
		end
	end
	vim.fn.mkdir(dir, "p")
	local f = assert(io.open(index_path(), "w"))
	f:write(vim.json.encode(data))
	f:close()
end

function M.entry(id)
	return M.index().pages[id]
end

---Merge `entry` into the stored entry for `id`.
function M.set_entry(id, entry)
	local pages = M.index().pages
	pages[id] = vim.tbl_extend("force", pages[id] or {}, entry)
	M.save_index()
end

-- Snapshot of the page body as last pulled/published; lets the UI diff without a request.
local function base_path(id)
	return config.sync_dir() .. "/.notion/base/" .. id .. ".md"
end

function M.save_base(id, body)
	local path = base_path(id)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(vim.split(body, "\n", { plain = true }), path)
end

---@return string?
function M.read_base(id)
	local path = base_path(id)
	if vim.fn.filereadable(path) == 1 then
		return table.concat(vim.fn.readfile(path), "\n")
	end
end

---Normalize a page ID or Notion URL to the dashed UUID form.
function M.normalize_id(s)
	if not s or s == "" then
		return nil
	end
	s = s:gsub("[?#].*$", "")
	s = (s:match("([^/]+)/*$") or s):gsub("-", "")
	local hex = s:match(("%x"):rep(32) .. "$")
	if not hex then
		return nil
	end
	hex = hex:lower()
	return ("%s-%s-%s-%s-%s"):format(hex:sub(1, 8), hex:sub(9, 12), hex:sub(13, 16), hex:sub(17, 20), hex:sub(21))
end

function M.hash(body)
	return vim.fn.sha256(body)
end

local FM_ORDER = { "notion_id", "title", "url", "parent" }

---Split buffer/file lines into frontmatter table and body string.
---@return table fm, string body, integer fm_len number of frontmatter lines
function M.split(lines)
	local fm, start = {}, 1
	if lines[1] == "---" then
		for i = 2, #lines do
			if lines[i] == "---" then
				for k = 2, i - 1 do
					local key, val = lines[k]:match("^([%w_]+):%s*(.-)%s*$")
					if key then
						if val:match('^".*"$') then
							local ok, dec = pcall(vim.json.decode, val)
							val = ok and dec or val
						end
						fm[key] = val
					end
				end
				start = i + 1
				break
			end
		end
	end
	local fm_len = start - 1
	local first, last = start, #lines
	while first <= last and vim.trim(lines[first]) == "" do
		first = first + 1
	end
	while last >= first and vim.trim(lines[last]) == "" do
		last = last - 1
	end
	return fm, table.concat(vim.list_slice(lines, first, last), "\n"), fm_len
end

function M.format_frontmatter(fm)
	local lines, seen = { "---" }, {}
	local function add(k)
		local v = fm[k]
		if v ~= nil and v ~= "" then
			v = tostring(v)
			if v:match("^[\"']") or v:match(":%s") or v:match("^%s") then
				v = vim.json.encode(v)
			end
			lines[#lines + 1] = k .. ": " .. v
		end
		seen[k] = true
	end
	for _, k in ipairs(FM_ORDER) do
		add(k)
	end
	local rest = vim.tbl_keys(fm)
	table.sort(rest)
	for _, k in ipairs(rest) do
		if not seen[k] then
			add(k)
		end
	end
	lines[#lines + 1] = "---"
	return lines
end

function M.format(fm, body)
	local lines = M.format_frontmatter(fm)
	lines[#lines + 1] = ""
	if body ~= "" then
		vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
	end
	return lines
end

function M.read(path)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	return M.split(vim.fn.readfile(path))
end

function M.write(path, fm, body)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(M.format(fm, body), path)
end

---A free file path in sync_dir for a page title.
function M.new_path(title, id)
	local name = (title or ""):gsub('[/\\:*?"<>|%c]', " "):gsub("%s+", " ")
	name = vim.fn.strcharpart(vim.trim(name), 0, 80)
	if name == "" or name:sub(1, 1) == "." then
		name = "Untitled" .. name
	end
	local dir = config.sync_dir()
	local path = dir .. "/" .. name .. ".md"
	if vim.uv.fs_stat(path) or M.path_owner(path) then
		path = ("%s/%s (%s).md"):format(dir, name, (id or tostring(os.time())):sub(1, 8))
	end
	return path
end

---@return string? id, table? entry
function M.path_owner(path)
	path = vim.fs.normalize(path)
	for id, e in pairs(M.index().pages) do
		if e.path == path then
			return id, e
		end
	end
end

---@return integer? buf loaded buffer showing `path`
function M.find_buf(path)
	path = vim.fs.normalize(path)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == path then
			return b
		end
	end
end

---Current lines of a doc: from its loaded buffer when open, else from disk.
---@return string[]?
function M.doc_lines(path)
	local buf = M.find_buf(path)
	if buf then
		return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	end
	if vim.fn.filereadable(path) == 1 then
		return vim.fn.readfile(path)
	end
end

---All known docs: synced pages plus local drafts in sync_dir.
---@return { id: string?, path: string, title: string, parent_id: string?, url: string?, body: string, status: "modified"|"new"|nil }[]
function M.docs()
	local docs, seen = {}, {}
	local function add(path, id)
		path = vim.fs.normalize(path)
		if seen[path] then
			return
		end
		local lines = M.doc_lines(path)
		if not lines then
			return
		end
		seen[path] = true
		local fm, body = M.split(lines)
		id = id or M.normalize_id(fm.notion_id)
		local e = id and M.entry(id)
		local status
		if not id then
			status = "new"
		elseif not e or e.hash ~= M.hash(body) then
			status = "modified"
		end
		docs[#docs + 1] = {
			id = id,
			path = path,
			title = fm.title or (e and e.title) or vim.fn.fnamemodify(path, ":t:r"),
			parent_id = (e and e.parent_id) or M.normalize_id(fm.parent),
			url = fm.url or (e and e.url),
			body = body,
			status = status,
		}
	end
	for id, e in pairs(M.index().pages) do
		if e.path then
			add(e.path, id)
		end
	end
	for _, p in ipairs(vim.fn.globpath(config.sync_dir(), "**/*.md", false, true)) do
		if not p:find("/%.notion/") then
			add(p)
		end
	end
	return docs
end

---Publish state of a buffer: "published" | "modified" | "new" | nil (not a Notion doc).
function M.buf_status(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return nil
	end
	local fm, body = M.split(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	local id = M.normalize_id(fm.notion_id)
	if not id then
		local in_sync_dir = vim.startswith(vim.fs.normalize(name), config.sync_dir() .. "/")
		return (in_sync_dir and name:match("%.md$")) and "new" or nil
	end
	local e = M.entry(id)
	if not e or e.hash ~= M.hash(body) then
		return "modified"
	end
	return "published"
end

return M
