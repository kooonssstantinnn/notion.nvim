local api = require("notion.api")
local async = require("notion.async")
local config = require("notion.config")
local diff = require("notion.diff")
local md = require("notion.markdown")
local store = require("notion.store")

local M = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Notion" })
end

local function reload(buf)
	vim.api.nvim_buf_call(buf, function()
		vim.cmd("silent edit!")
	end)
end

local function emit(event, data)
	vim.api.nvim_exec_autocmds("User", { pattern = event, data = data })
end

-- Only page parents form the tree; database rows and workspace pages are roots.
local function parent_of(page)
	return page.parent and page.parent.page_id or nil
end

-------------------------------------------------------------------------------
-- Pull
-------------------------------------------------------------------------------

---Download one page into its local file.
---@return "pulled"|"conflict"
function M.pull_page(page, force)
	local id = page.id
	local title_prop, title = api.page_title(page)
	local entry = store.entry(id)
	local path = entry and entry.path or store.new_path(title, id)
	local fm = {}

	if vim.uv.fs_stat(path) then
		local cur_fm, body = store.read(path)
		fm = cur_fm or {}
		if not force and entry and store.hash(body) ~= entry.hash then
			return "conflict"
		end
	end
	local buf = store.find_buf(path)
	if buf and vim.bo[buf].modified and not force then
		return "conflict"
	end

	local body = md.render(api.fetch_tree(id))
	fm.notion_id, fm.title, fm.url = id, title, page.url
	store.write(path, fm, body)
	store.save_base(id, body)
	store.set_entry(id, {
		path = path,
		title = title,
		title_prop = title_prop,
		parent_id = parent_of(page),
		url = page.url,
		last_edited = page.last_edited_time,
		hash = store.hash(body),
	})
	if buf then
		reload(buf)
	end
	return "pulled"
end

local function keep_ids(text)
	local ids = {}
	for id in (text or ""):gmatch("<!%-%- notion:keep (%S+)") do
		ids[id] = true
	end
	return ids
end

---Does the last-synced copy of page `id` disagree with the sub-pages we know about?
function M.children_stale(id)
	local base = store.read_base(id)
	if not base then
		return false
	end
	local pages = store.index().pages
	for cid, ce in pairs(pages) do
		if ce.parent_id == id and ce.title then
			local t = base:match("<!%-%- notion:keep " .. vim.pesc(cid) .. " child_page: (.-) %-%->")
			if t ~= ce.title then
				return true
			end
		end
	end
	for cid in base:gmatch("<!%-%- notion:keep (%S+) child_page") do
		if pages[cid] and pages[cid].parent_id ~= id then
			return true
		end
	end
	return false
end

---Was this page written by an older version that used <br> lines for empty blocks?
function M.legacy_format(id)
	local base = store.read_base(id)
	return base ~= nil and ("\n" .. base .. "\n"):find("\n%s*<br>\n") ~= nil
end

function M.sync()
	async.run(function()
		notify("Syncing…")
		local pages = api.search_pages()
		local results, by_id = {}, {}
		for _, page in ipairs(pages) do
			if not (page.archived or page.in_trash) and (not config.options.filter or config.options.filter(page)) then
				by_id[page.id] = page
				local e = store.entry(page.id)
				local status = "current"
				if not e or not vim.uv.fs_stat(e.path) or page.last_edited_time > (e.last_edited or "") then
					status = M.pull_page(page, false)
				else
					local _, title = api.page_title(page)
					if e.parent_id ~= parent_of(page) or e.title ~= title then
						store.set_entry(page.id, { parent_id = parent_of(page), title = title })
					end
				end
				results[page.id] = status
			end
		end
		-- Adding, renaming or moving a sub-page doesn't bump the parent's last_edited_time,
		-- so also re-pull parents whose sub-page placeholders no longer match.
		for id, page in pairs(by_id) do
			if results[id] == "current" and (M.children_stale(id) or M.legacy_format(id)) then
				results[id] = M.pull_page(page, false)
			end
		end

		local counts = { pulled = 0, current = 0, conflict = 0 }
		local conflicts = {}
		for id, status in pairs(results) do
			counts[status] = counts[status] + 1
			if status == "conflict" then
				conflicts[#conflicts + 1] = "  " .. select(2, api.page_title(by_id[id]))
			end
		end
		store.index().last_sync = os.time()
		store.save_index()
		emit("NotionSynced")
		local msg = ("Synced %d pages: %d updated, %d up to date"):format(#pages, counts.pulled, counts.current)
		if counts.conflict > 0 then
			msg = msg
				.. ("\n%d changed in Notion but have unpublished local edits (use :Notion pull! to overwrite, or :Notion diff):\n"):format(
					counts.conflict
				)
				.. table.concat(conflicts, "\n")
			notify(msg, vim.log.levels.WARN)
		else
			notify(msg)
		end
	end)
end

---Re-download the page in the current buffer.
function M.pull(buf, force)
	async.run(function()
		local fm = store.split(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		local id = store.normalize_id(fm.notion_id)
		if not id then
			error("This buffer is not linked to a Notion page (no notion_id in frontmatter)", 0)
		end
		if not force and store.buf_status(buf) == "modified" then
			if
				not async.confirm(
					"Discard your unpublished local changes and pull this page from Notion?",
					"Discard & pull",
					{
						title = "Pull from Notion",
					}
				)
			then
				return
			end
		end
		local page = api.get_page(id)
		local entry = store.entry(id)
		if not entry then
			-- Page known from frontmatter only (e.g. file copied from another machine): adopt this file.
			store.set_entry(id, { path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) })
		end
		if vim.bo[buf].modified then
			vim.bo[buf].modified = false
		end
		M.pull_page(page, true)
		emit("NotionPulled", { id = id, buf = buf })
		notify("Pulled “" .. select(2, api.page_title(page)) .. "”")
	end)
end

-------------------------------------------------------------------------------
-- Publish
-------------------------------------------------------------------------------

local function count_children(blocks)
	local out = {}
	for _, b in ipairs(blocks or {}) do
		if not b._keep then
			out[#out + 1] = b
		end
	end
	return out
end

local function kids_of(b)
	return b[b.type] and b[b.type].children
end

-- Request payload with children inlined one level deep (tables keep their rows).
local function payload(b, depth)
	local data = {}
	for k, v in pairs(b[b.type]) do
		if k ~= "children" then
			data[k] = v
		end
	end
	local kids = count_children(kids_of(b))
	if #kids > 0 and (depth == 0 or b.type == "table") then
		data.children = vim.tbl_map(function(c)
			return payload(c, depth + 1)
		end, kids)
	end
	if next(data) == nil then
		data = vim.empty_dict()
	end
	return { object = "block", type = b.type, [b.type] = data }
end

---Append blocks (any depth) under parent, after block id `after` (nil = end).
local function append_tree(parent, blocks, after)
	for start = 1, #blocks, 100 do
		local chunk = vim.list_slice(blocks, start, start + 99)
		local res = api.append_children(
			parent,
			vim.tbl_map(function(b)
				return payload(b, 0)
			end, chunk),
			after
		)
		local created = res.results or {}
		for k, b in ipairs(chunk) do
			local kids = count_children(kids_of(b))
			local deep = false
			for _, c in ipairs(kids) do
				if #count_children(kids_of(c)) > 0 then
					deep = true
				end
			end
			if deep and b.type ~= "table" and created[k] then
				local remote_kids = api.list_children(created[k].id)
				for m, c in ipairs(kids) do
					local grand = count_children(kids_of(c))
					if #grand > 0 and remote_kids[m] then
						append_tree(remote_kids[m].id, grand)
					end
				end
			end
		end
		after = created[#chunk] and created[#chunk].id or after
	end
end

-- Notion rejects anything that isn't a real absolute URL (e.g. "https://…").
local function is_url(u)
	if u:match("^mailto:[^%s@]+@[^%s@]+%.%w+$") or u:match("^tel:%+?[%d%-%.() ]+$") then
		return true
	end
	local host = u:match("^https?://([^/?#:%s]+)")
	return host ~= nil and not u:find("%s") and host:match("^[%w%-]+%.[%w%-%.]*%w$") ~= nil
end

---Turn a markdown link target into something Notion accepts, or nil to drop the link.
---@param dir string directory of the file being published (for relative .md links)
function M.resolve_link(url, dir)
	url = vim.trim(url or ""):gsub("^<(.*)>$", "%1")
	if is_url(url) then
		return url
	end
	if url:match("^www%.[%w-]+%.%S+$") then
		return "https://" .. url
	end
	local hex = url:gsub("-", ""):match("^/?(" .. ("%x"):rep(32) .. ")[?#]?")
	if hex then
		return "https://www.notion.so/" .. hex
	end
	-- [text](Other.md) / [text](../notion/Other.md#section) -> that page's Notion URL
	local file = url:gsub("#.*$", ""):gsub("%%20", " ")
	if file:match("%.md$") then
		local id, e = store.path_owner(vim.fs.normalize(file:sub(1, 1) == "/" and file or (dir .. "/" .. file)))
		if id then
			return (e and e.url) or ("https://www.notion.so/" .. id:gsub("-", ""))
		end
	end
	return nil
end

---Fix links and image URLs in parsed blocks before sending them. Returns warnings.
local function sanitize(blocks, dir)
	local dropped, warnings = {}, {}
	local function rich_text(list)
		for _, rt in ipairs(list or {}) do
			local link = rt.text and rt.text.link
			if link then
				local fixed = M.resolve_link(link.url, dir)
				if fixed then
					link.url = fixed
				else
					dropped[#dropped + 1] = link.url
					rt.text.link = nil
				end
			end
		end
	end
	local function walk(list)
		for idx, b in ipairs(list or {}) do
			local d = b[b.type]
			if type(d) == "table" then
				if b.type == "image" and not is_url(d.external.url) then
					warnings[#warnings + 1] = ("image “%s” is not an http(s) URL; published as text"):format(
						d.external.url
					)
					list[idx] = {
						type = "paragraph",
						paragraph = {
							rich_text = { { type = "text", text = { content = "🖼 " .. d.external.url } } },
						},
					}
				else
					rich_text(d.rich_text)
					rich_text(d.caption)
					for _, cell in ipairs(d.cells or {}) do
						rich_text(cell)
					end
					walk(d.children)
				end
			end
		end
	end
	walk(blocks)
	if #dropped > 0 then
		warnings[#warnings + 1] = "Notion only accepts full URLs, so these links were published as plain text: "
			.. table.concat(dropped, ", ")
	end
	return warnings
end

local function first_heading(body)
	for line in (body .. "\n"):gmatch("(.-)\n") do
		local h = line:match("^#%s+(.+)$")
		if h then
			return vim.trim(h)
		end
	end
end

local function choose_parent(fm, title)
	local parent = store.normalize_id(fm.parent) or store.normalize_id(config.options.default_parent)
	if parent then
		return parent
	end
	local items = {}
	for id, e in pairs(store.index().pages) do
		items[#items + 1] = { id = id, title = e.title or "Untitled" }
	end
	table.sort(items, function(a, b)
		return a.title:lower() < b.title:lower()
	end)
	items[#items + 1] = { title = "Enter a page URL or ID…" }
	local choice = async.select(items, {
		title = "New Notion page",
		prompt = ("Where should “%s” be created?"):format(title),
		format_item = function(it)
			return it.title
		end,
	})
	if not choice then
		return nil
	end
	if choice.id then
		return choice.id
	end
	local input = async.input({ prompt = "Parent page URL or ID" })
	local id = store.normalize_id(input)
	if input and not id then
		error("Could not find a page ID in: " .. input, 0)
	end
	return id
end

local function set_frontmatter(buf, fm, fm_len)
	vim.api.nvim_buf_set_lines(buf, 0, fm_len, false, store.format_frontmatter(fm))
	if fm_len == 0 then
		vim.api.nvim_buf_set_lines(buf, #store.format_frontmatter(fm), #store.format_frontmatter(fm), false, { "" })
	end
	vim.api.nvim_buf_call(buf, function()
		vim.cmd("silent write")
	end)
end

function M.publish(buf)
	async.run(function()
		local path = vim.api.nvim_buf_get_name(buf)
		if path == "" then
			error("Save this buffer to a file before publishing", 0)
		end
		if vim.bo[buf].modified then
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("silent write")
			end)
		end
		local fm, body, fm_len = store.split(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		local id = store.normalize_id(fm.notion_id)
		local title = fm.title or first_heading(body) or vim.fn.fnamemodify(path, ":t:r")
		local creating = false

		if not id then
			local parent = choose_parent(fm, title)
			if not parent then
				return
			end
			local parent_entry = store.entry(parent)
			if
				config.options.confirm_publish
				and not async.confirm(("Create “%s” in Notion?"):format(title), "Create page", {
					title = "Publish to Notion",
					detail = parent_entry and parent_entry.title and ("Inside “" .. parent_entry.title .. "”")
						or nil,
				})
			then
				return
			end
			local page = api.create_page(parent, title)
			id, creating = page.id, true
			fm.notion_id, fm.title, fm.url, fm.parent = id, title, page.url, nil
			set_frontmatter(buf, fm, fm_len)
			store.set_entry(id, { path = vim.fs.normalize(path), title = title, url = page.url, parent_id = parent })
		end

		local page = api.get_page(id)
		local entry = store.entry(id)
		if not creating and (not entry or not entry.last_edited or page.last_edited_time > entry.last_edited) then
			local reason = entry and entry.last_edited and "This page was edited in Notion since your last sync."
				or "This page was never synced on this machine."
			local choice = async.select({ "Overwrite Notion", "Show diff", "Cancel" }, {
				title = "Notion has other changes",
				prompt = reason,
				detail = "Overwriting replaces the Notion version with your local file.",
			})
			if choice == "Show diff" then
				vim.schedule(function()
					M.diff(buf)
				end)
				return
			elseif choice ~= "Overwrite Notion" then
				return
			end
		end

		local remote = api.fetch_tree(id)
		-- Only sub-pages/blocks that existed at the last sync may be deleted (see diff.plan).
		local base = store.read_base(id)
		local local_blocks = md.parse(body)
		local link_warnings = sanitize(local_blocks, vim.fs.dirname(vim.fs.normalize(path)))
		local plan = diff.plan(remote, local_blocks, base and keep_ids(base) or nil)
		vim.list_extend(plan.warnings, link_warnings)
		local _, remote_title = api.page_title(page)
		local title_changed = remote_title ~= title

		if #plan.deletes == 0 and plan.inserted == 0 and not title_changed then
			notify("Already up to date with Notion")
		else
			if config.options.confirm_publish and not creating then
				local parts = {}
				if plan.inserted > 0 then
					parts[#parts + 1] = ("%d block%s added"):format(plan.inserted, plan.inserted == 1 and "" or "s")
				end
				if #plan.deletes > 0 then
					parts[#parts + 1] = ("%d removed"):format(#plan.deletes)
				end
				if title_changed then
					parts[#parts + 1] = ("title → “%s”"):format(title)
				end
				if plan.rewrite then
					parts[#parts + 1] = "whole page rewritten"
				end
				if
					not async.confirm(("Publish “%s” to Notion?"):format(title), "Publish", {
						title = "Publish to Notion",
						detail = table.concat(parts, " · "),
					})
				then
					return
				end
			end
			notify("Publishing “" .. title .. "”…")
			-- Add first, delete after: if Notion rejects something, nothing has been removed yet.
			for _, g in ipairs(plan.groups) do
				append_tree(id, g.blocks, g.after)
			end
			for _, bid in ipairs(plan.deletes) do
				api.delete_block(bid)
			end
			if title_changed then
				api.set_title(page, title)
			end
			if plan.protected > 0 then
				plan.warnings[#plan.warnings + 1] = ("Left %d block%s in Notion that were added after your last sync (e.g. new sub-pages). :Notion pull to see them."):format(
					plan.protected,
					plan.protected == 1 and "" or "s"
				)
			end
			for _, w in ipairs(plan.warnings) do
				notify(w, vim.log.levels.WARN)
			end
			page = api.get_page(id)
			notify("Published “" .. title .. "” ✓")
		end

		store.set_entry(id, {
			path = vim.fs.normalize(path),
			title = title,
			title_prop = api.page_title(page),
			url = page.url,
			last_edited = page.last_edited_time,
			hash = store.hash(body),
		})
		store.save_base(id, body)
		emit("NotionPublished", { id = id, buf = buf })
	end)
end

-------------------------------------------------------------------------------
-- Diff / status
-------------------------------------------------------------------------------

function M.diff(buf)
	async.run(function()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local fm, _, fm_len = store.split(lines)
		local id = store.normalize_id(fm.notion_id)
		if not id then
			error("This buffer has not been published to Notion yet", 0)
		end
		local body = md.render(api.fetch_tree(id))
		local remote_lines = vim.list_slice(lines, 1, fm_len)
		if fm_len > 0 then
			remote_lines[#remote_lines + 1] = ""
		end
		vim.list_extend(remote_lines, body ~= "" and vim.split(body, "\n", { plain = true }) or {})

		local win = vim.fn.bufwinid(buf)
		if win ~= -1 then
			vim.api.nvim_set_current_win(win)
		end
		vim.cmd("diffthis")
		vim.cmd("vertical leftabove new")
		local scratch = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(scratch, 0, -1, false, remote_lines)
		vim.bo[scratch].buftype = "nofile"
		vim.bo[scratch].bufhidden = "wipe"
		vim.bo[scratch].modifiable = false
		vim.bo[scratch].filetype = "markdown"
		pcall(vim.api.nvim_buf_set_name, scratch, "notion://remote/" .. id)
		vim.cmd("diffthis")
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = scratch,
			once = true,
			callback = function()
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_buf_call(buf, function()
						vim.cmd("diffoff")
					end)
				end
			end,
		})
		notify("Left: Notion, right: local. Close the left window to end the diff.")
	end)
end

---Quickfix list of documents with unpublished changes.
function M.status()
	local items = {}
	for _, d in ipairs(store.docs()) do
		if d.status then
			local state = d.status == "new" and "new, never published" or "unpublished changes"
			items[#items + 1] = { filename = d.path, lnum = 1, text = d.title .. " — " .. state }
		end
	end
	if #items == 0 then
		notify("Everything is published ✓")
		return
	end
	vim.fn.setqflist({}, " ", { title = "Notion: unpublished", items = items })
	vim.cmd("copen")
end

return M
