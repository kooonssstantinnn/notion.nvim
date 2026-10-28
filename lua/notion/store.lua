-- Local files, frontmatter and the sync index.
local config = require("notion.config")

local M = {}

local index, index_dir, index_stamp

local function index_path()
	return config.sync_dir() .. "/.notion-index.json"
end

-- Identifies the index file's version on disk, so changes made by another Neovim are noticed.
local function stamp()
	local st = vim.uv.fs_stat(index_path())
	return st and ("%d.%d.%d"):format(st.mtime.sec, st.mtime.nsec, st.size) or nil
end

-- Paths are stored relative to sync_dir on disk so the folder can be moved or committed.
-- Re-read whenever the file changed on disk: every change is saved right away, so the
-- cached copy never has unsaved edits, and a stale copy must not overwrite another
-- Neovim's changes (e.g. the Working list).
function M.index()
	local dir = config.sync_dir()
	local current = stamp()
	if not index or index_dir ~= dir or current ~= index_stamp then
		index, index_dir, index_stamp = { pages = {} }, dir, current
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
					-- Older versions stored titles with newlines.
					if type(e.title) == "string" then
						e.title = vim.trim((e.title:gsub("%c", " ")))
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
	local data = vim.deepcopy(index_dir == dir and index or M.index())
	for _, e in pairs(data.pages) do
		if e.path and vim.startswith(e.path, dir .. "/") then
			e.path = e.path:sub(#dir + 2)
		end
	end
	vim.fn.mkdir(dir, "p")
	local f = assert(io.open(index_path(), "w"))
	f:write(vim.json.encode(data))
	f:close()
	index_stamp = stamp()
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
---@return table fm, string body, integer fm_len number of frontmatter lines, integer body_start line of the body's first line
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
							val = ok and type(dec) == "string" and dec or val
						end
						-- Older files may hold control chars (a newline in a title is written as NUL).
						fm[key] = vim.trim((val:gsub("%c", " ")))
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
	return fm, table.concat(vim.list_slice(lines, first, last), "\n"), fm_len, first
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
	local function taken(p)
		return vim.uv.fs_stat(p) or M.path_owner(p)
	end
	local path = dir .. "/" .. name .. ".md"
	if taken(path) then
		-- IDs in one workspace often share a prefix, so use the tail and fall back to the full ID.
		local hex = (id or tostring(os.time())):gsub("-", "")
		path = ("%s/%s (%s).md"):format(dir, name, hex:sub(-8))
		if taken(path) then
			path = ("%s/%s (%s).md"):format(dir, name, hex)
		end
	end
	return path
end

---Can page `id` use the file at `path`? False when the file is linked to another page.
function M.owns(id, path)
	local lines = M.doc_lines(path)
	if not lines then
		return true
	end
	local fid = M.normalize_id(M.split(lines).notion_id)
	return fid == nil or fid == id
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
---@return { id: string?, path: string, title: string, parent_id: string?, url: string?, body: string, body_start: integer, status: "modified"|"new"|nil }[]
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
		local fm, body, _, body_start = M.split(lines)
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
			title = vim.trim(((fm.title or (e and e.title) or vim.fn.fnamemodify(path, ":t:r")):gsub("%c", " "))),
			parent_id = (e and e.parent_id) or M.normalize_id(fm.parent),
			url = fm.url or (e and e.url),
			body = body,
			body_start = body_start,
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

---Does sync download every page (true) or only pages already pulled (false)?
---Chosen per folder in the dashboard (`S`); the `sync_all` option is the default.
function M.sync_all()
	local v = M.index().sync_all
	if v == nil then
		return config.options.sync_all ~= false
	end
	return v
end

function M.set_sync_all(on)
	M.index().sync_all = on
	M.save_index()
end

---Does the local copy of page `id` have edits that weren't published (saved or not)?
function M.has_edits(id)
	local e = M.entry(id)
	if not e or not e.path then
		return false
	end
	local buf = M.find_buf(e.path)
	if buf and vim.bo[buf].modified then
		return true
	end
	local lines = M.doc_lines(e.path)
	if not lines then
		return false
	end
	local _, body = M.split(lines)
	return M.hash(body) ~= e.hash
end

---Forget page `id`: delete its file (if it's really its own), base copy and index entry.
function M.remove_page(id)
	local e = M.entry(id)
	if not e then
		return
	end
	if e.path and M.owns(id, e.path) then
		local buf = M.find_buf(e.path)
		if buf then
			pcall(vim.api.nvim_buf_delete, buf, {})
		end
		os.remove(e.path)
	end
	os.remove(base_path(id))
	M.set_working({ id = id, path = e.path }, false)
	M.index().pages[id] = nil
	M.save_index()
end

-------------------------------------------------------------------------------
-- Working set: the docs you're focused on, kept per folder in the index.
-- Synced pages are stored by ID, drafts by path (relative to sync_dir when inside it).
-------------------------------------------------------------------------------

local function work_keys(d)
	local keys = {}
	if d.id then
		keys[#keys + 1] = d.id
	end
	if d.path then
		local path, dir = vim.fs.normalize(d.path), config.sync_dir()
		keys[#keys + 1] = vim.startswith(path, dir .. "/") and path:sub(#dir + 2) or path
	end
	return keys
end

---@param d { id: string?, path: string? }
function M.is_working(d)
	local set = M.index().working or {}
	for _, k in ipairs(work_keys(d)) do
		if vim.tbl_contains(set, k) then
			return true
		end
	end
	return false
end

---@param d { id: string?, path: string? }
function M.set_working(d, on)
	local idx = M.index()
	local keys = work_keys(d)
	local set = vim.tbl_filter(function(k)
		return not vim.tbl_contains(keys, k)
	end, idx.working or {})
	if on then
		set[#set + 1] = keys[1]
	end
	idx.working = set
	M.save_index()
end

-------------------------------------------------------------------------------
-- Search
-------------------------------------------------------------------------------

---Search words: whitespace-separated, all must appear. Smartcase like Vim.
---@return string[] words, boolean ignorecase
function M.parse_query(query)
	local words = vim.split(vim.trim(query or ""), "%s+", { trimempty = true })
	return words, not (query or ""):find("%u")
end

---Find docs containing every word of `query` in the title or body.
---Title hits come first; `lnum` is the file line of the first body line with a match.
---@return { doc: table, title_hit: boolean, lnum: integer? }[]
function M.search(docs, query)
	local words, icase = M.parse_query(query)
	if #words == 0 then
		return {}
	end
	local function norm(s)
		return icase and s:lower() or s
	end
	for i, w in ipairs(words) do
		words[i] = norm(w)
	end
	local out = {}
	for _, d in ipairs(docs) do
		local title, body = norm(d.title), norm(d.body)
		local all, title_hit = true, true
		for _, w in ipairs(words) do
			local in_title = title:find(w, 1, true) ~= nil
			title_hit = title_hit and in_title
			if not in_title and not body:find(w, 1, true) then
				all = false
				break
			end
		end
		if all then
			local lnum
			local i = 0
			for line in (body .. "\n"):gmatch("(.-)\n") do
				for _, w in ipairs(words) do
					if norm(line):find(w, 1, true) then
						lnum = (d.body_start or 1) + i
						break
					end
				end
				if lnum then
					break
				end
				i = i + 1
			end
			out[#out + 1] = { doc = d, title_hit = title_hit, lnum = lnum }
		end
	end
	table.sort(out, function(a, b)
		if a.title_hit ~= b.title_hit then
			return a.title_hit
		end
		return a.doc.title:lower() < b.doc.title:lower()
	end)
	return out
end

---Vim regex matching any word of `query` (for highlighting and `n`).
function M.query_pattern(query)
	local words, icase = M.parse_query(query)
	local escaped = vim.tbl_map(function(w)
		return (w:gsub("\\", "\\\\"))
	end, words)
	return (icase and "\\c" or "\\C") .. "\\V\\(" .. table.concat(escaped, "\\|") .. "\\)"
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
