-- lazygit-style dashboard: status, page tree, unpublished list and a preview.
local config = require("notion.config")
local store = require("notion.store")

local M = {}

local ns = vim.api.nvim_create_namespace("notion.ui")
local PANELS = { "status", "working", "pages", "changes", "preview", "hints" }
local TITLES = {
	status = "[1] Status",
	working = "[2] Working",
	pages = "[3] Pages",
	changes = "[4] Unpublished",
	preview = "[0] Preview",
}
local CYCLE = { "working", "pages", "changes", "preview" }
local LISTS = { working = true, pages = true, changes = true }
local MARK = { modified = { "M", "NotionModified" }, new = { "A", "NotionNew" } }

local HINTS = {
	{ "Open", "⏎" },
	{ "Search", "/" },
	{ "Get", "g" },
	{ "Work", "w" },
	{ "Publish", "p" },
	{ "Sync", "s" },
	{ "Mode", "S" },
	{ "Pull", "P" },
	{ "Diff", "d" },
	{ "New", "n" },
	{ "Browser", "o" },
	{ "Fold", "␣" },
	{ "Close", "q" },
	{ "Keys", "?" },
}

local HELP = {
	"# Keys",
	"",
	"- `⏎` / `e`  open the page for editing (at the first match when searching)",
	"- `/`  search pages by title and content (`Esc` clears the search)",
	"- `g`  get one page from Notion by URL, ID or title, optionally with its sub-pages",
	"- `w`  add or remove the page from Working",
	"- `p`  publish the page to Notion",
	"- `s`  sync: pull everything changed in Notion (or only pages you have, see `S`)",
	"- `S`  sync mode: all pages, or only pages you already pulled and new sub-pages under them",
	"- `P`  pull this page (discards local edits after asking)",
	"- `d`  diff with the live Notion page, shown here (`Esc` goes back to the preview)",
	"- `D`  full-screen side-by-side diff",
	"- `n`  new local draft",
	"- `o`  open in browser",
	"- `␣` / `za`  fold or unfold, `h` / `l`  collapse or expand",
	"- `r`  refresh",
	"- `L`  log in to Notion for this folder",
	"- `1` `2` `3` `4` `0`  jump to a panel, `⇥` / `⇧⇥`  cycle panels",
	"- `q` / `Esc`  close",
	"",
	"`M` = unpublished changes, `A` = new draft, never published, `★` = in Working.",
	"`:w` in a page only saves locally. Nothing reaches Notion until you publish.",
}

local collapsed = {} -- page id -> true; survives closing the UI
local state ---@type table?

local function set_hl()
	local function link(name, to)
		vim.api.nvim_set_hl(0, name, { link = to, default = true })
	end
	link("NotionActiveBorder", "DiagnosticOk")
	link("NotionModified", "DiagnosticWarn")
	link("NotionNew", "DiagnosticOk")
	link("NotionKey", "Function")
	link("NotionDim", "Comment")
end

local function layout()
	local W = vim.o.columns
	local avail = vim.o.lines - vim.o.cmdheight - 1
	local lw = math.max(30, math.floor(W * 0.38))
	local s_out = 5
	local rest = avail - s_out
	local w_out = math.max(4, math.floor(rest * 0.3))
	local c_out = math.max(4, math.floor(rest * 0.2))
	local p_out = rest - w_out - c_out
	local function box(row, col, w, h)
		return {
			relative = "editor",
			row = row,
			col = col,
			width = math.max(1, w - 2),
			height = math.max(1, h - 2),
			border = "rounded",
			style = "minimal",
			zindex = 50,
		}
	end
	return {
		status = box(0, 0, lw, s_out),
		working = box(s_out, 0, lw, w_out),
		pages = box(s_out + w_out, 0, lw, p_out),
		changes = box(s_out + w_out + p_out, 0, lw, c_out),
		preview = box(0, lw, W - lw, avail),
		hints = {
			relative = "editor",
			row = avail,
			col = 0,
			width = W,
			height = 1,
			style = "minimal",
			focusable = false,
			zindex = 50,
		},
	}
end

local function set_lines(name, lines)
	local buf = state.bufs[name]
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

local function hl(name, row, col, end_col, group)
	vim.api.nvim_buf_set_extmark(state.bufs[name], ns, row, col, { end_col = end_col, hl_group = group })
end

local function set_title(name, title)
	vim.api.nvim_win_set_config(state.wins[name], { title = " " .. title .. " ", title_pos = "left" })
end

-------------------------------------------------------------------------------
-- Rows
-------------------------------------------------------------------------------

local function by_title(a, b)
	return a.title:lower() < b.title:lower()
end

local function build_tree(docs)
	local ids, children, roots = {}, {}, {}
	for _, d in ipairs(docs) do
		if d.id then
			ids[d.id] = true
		end
	end
	for _, d in ipairs(docs) do
		local p = d.parent_id
		if p and ids[p] and p ~= d.id then
			children[p] = children[p] or {}
			table.insert(children[p], d)
		else
			roots[#roots + 1] = d
		end
	end
	local rows = {}
	local function walk(list, depth)
		table.sort(list, by_title)
		for _, d in ipairs(list) do
			local kids = d.id and children[d.id]
			rows[#rows + 1] = { doc = d, depth = depth, has_kids = kids ~= nil }
			if kids and not collapsed[d.id] then
				walk(kids, depth + 1)
			end
		end
	end
	walk(roots, 0)
	return rows
end

-- Docs in the working set plus all their sub-pages.
local function working_docs(docs)
	local kids = {}
	for _, d in ipairs(docs) do
		if d.parent_id then
			kids[d.parent_id] = kids[d.parent_id] or {}
			table.insert(kids[d.parent_id], d)
		end
	end
	local out, seen = {}, {}
	local function add(d)
		if seen[d.path] then
			return
		end
		seen[d.path] = true
		out[#out + 1] = d
		for _, c in ipairs(d.id and kids[d.id] or {}) do
			add(c)
		end
	end
	for _, d in ipairs(docs) do
		if store.is_working(d) then
			add(d)
		end
	end
	return out
end

local function render_rows(name, rows, empty)
	if #rows == 0 then
		set_lines(name, { "  " .. empty })
		hl(name, 0, 0, #empty + 2, "NotionDim")
		return
	end
	local lines = {}
	for i, r in ipairs(rows) do
		local mark = MARK[r.doc.status]
		local glyph = r.has_kids and (collapsed[r.doc.id] and "▸ " or "▾ ") or "  "
		local prefix = (mark and mark[1] or " ") .. " " .. ("  "):rep(r.depth)
		lines[i] = prefix .. glyph .. r.doc.title
		r.glyph_col = #prefix
	end
	set_lines(name, lines)
	for i, r in ipairs(rows) do
		local mark = MARK[r.doc.status]
		if mark then
			hl(name, i - 1, 0, 1, mark[2])
		end
		if r.has_kids then
			hl(name, i - 1, r.glyph_col, r.glyph_col + #"▾", "NotionDim")
		end
		if name ~= "working" and store.is_working(r.doc) then
			vim.api.nvim_buf_set_extmark(state.bufs[name], ns, i - 1, 0, {
				virt_text = { { " ★", "NotionKey" } },
				virt_text_pos = "eol",
			})
		end
	end
end

local function ago(t)
	if not t then
		return "never synced"
	end
	local d = os.time() - t
	if d < 60 then
		return "synced just now"
	elseif d < 3600 then
		return ("synced %dm ago"):format(math.floor(d / 60))
	elseif d < 86400 then
		return ("synced %dh ago"):format(math.floor(d / 3600))
	end
	return ("synced %dd ago"):format(math.floor(d / 86400))
end

local function render_status(docs)
	local pages, dirty = 0, 0
	for _, d in ipairs(docs) do
		if d.id then
			pages = pages + 1
		end
		if d.status then
			dirty = dirty + 1
		end
	end
	local auth = config.folder_auth()
	local l0
	if auth then
		local who = auth.workspace and (auth.workspace .. " · " .. (auth.name or "")) or (auth.name or "logged in")
		l0 = " ● " .. who
	elseif config.token() then
		l0 = " ● using " .. (config.options.token and "token from setup()" or ("$" .. config.options.token_env))
	else
		l0 = " ○ Not logged in · press L"
	end
	local mode = store.sync_all() and "sync: all" or "sync: pulled only"
	local l1 = (" %d pages · %d unpublished · %s"):format(pages, dirty, mode)
	local l2 = (" %s · %s"):format(ago(store.index().last_sync), vim.fn.fnamemodify(config.sync_dir(), ":~"))
	set_lines("status", { l0, l1, l2 })
	hl("status", 0, 0, #l0, config.token() and "NotionNew" or "NotionModified")
	if dirty > 0 then
		local s, e = l1:find("%d+ unpublished")
		hl("status", 1, s - 1, e, "NotionModified")
	end
	hl("status", 1, #l1 - #mode, #l1, "NotionDim")
	hl("status", 2, 0, #l2, "NotionDim")
end

local function render_hints()
	local parts, marks, col = {}, {}, 1
	for i, h in ipairs(HINTS) do
		local label = h[1] .. ": "
		local seg = (i > 1 and " | " or " ") .. label
		parts[#parts + 1] = seg .. h[2]
		marks[#marks + 1] = { col + #seg - 1, col + #seg - 1 + #h[2] }
		col = col + #seg + #h[2]
	end
	set_lines("hints", { table.concat(parts) })
	for _, m in ipairs(marks) do
		hl("hints", 0, m[1], m[2], "NotionKey")
	end
end

-------------------------------------------------------------------------------
-- Selection & preview
-------------------------------------------------------------------------------

local function list_panel()
	if LISTS[state.focus] then
		return state.focus
	end
	return state.last_list or "pages"
end

local function current_row(name)
	name = name or list_panel()
	local row = vim.api.nvim_win_get_cursor(state.wins[name])[1]
	return state.rows[name][row]
end

local function current_doc()
	local r = current_row()
	return r and r.doc
end

---@param cursor? integer line to scroll to (a search match)
local function show_preview(lines, ft, title, cursor)
	set_lines("preview", lines)
	local buf, win = state.bufs.preview, state.wins.preview
	if vim.bo[buf].filetype ~= ft then
		vim.bo[buf].filetype = ft
	end
	set_title("preview", title)
	if state.match then
		pcall(vim.fn.matchdelete, state.match, win)
		state.match = nil
	end
	if state.query then
		state.match = vim.fn.matchadd("Search", store.query_pattern(state.query), 10, -1, { window = win })
	end
	pcall(vim.api.nvim_win_set_cursor, win, { cursor or 1, 0 })
	if cursor then
		vim.api.nvim_win_call(win, function()
			vim.cmd("normal! zz")
		end)
	end
end

local function update_preview()
	if not state then
		return
	end
	local d = current_doc()
	if d and state.diff and state.diff.path == d.path then
		show_preview(state.diff.lines, state.diff.ft, state.diff.title)
		return
	end
	state.diff = nil
	if not d then
		local msg = list_panel() == "working"
				and {
					"",
					"  Nothing in Working yet.",
					"",
					"  Press `w` on a page to add it here (its sub-pages come with it),",
					"  or `g` to get a page from Notion.",
				}
			or {
				"",
				"  No pages yet.",
				"",
				"  Press `s` to sync, `g` to get one page from Notion or `n` to start a draft.",
			}
		show_preview(msg, "markdown", TITLES.preview)
		return
	end
	local base = d.status == "modified" and store.read_base(d.id)
	if base then
		local u = vim.diff(base .. "\n", d.body .. "\n", { result_type = "unified", ctxlen = 3 })
		local lines = { "--- Notion (last sync)", "+++ local" }
		vim.list_extend(lines, vim.split(vim.trim(u), "\n", { plain = true }))
		show_preview(lines, "diff", "[0] Unpublished changes · " .. d.title)
	else
		local lines = d.body ~= "" and vim.split(d.body, "\n", { plain = true }) or { "_(empty)_" }
		local r = current_row()
		local cursor = r and r.lnum and (r.lnum - (d.body_start or 1) + 1)
		show_preview(lines, "markdown", "[0] " .. d.title .. (d.status == "new" and " · draft" or ""), cursor)
	end
end

---Re-read docs and redraw every panel, keeping the selected doc selected.
---@param cached? boolean reuse the docs read by the last refresh (for live search)
function M.refresh(cached)
	if not state then
		return
	end
	local keep = {}
	for _, name in ipairs({ "working", "pages", "changes" }) do
		local r = current_row(name)
		keep[name] = r and r.doc.path
	end

	local docs = (cached == true and state.docs) or store.docs()
	state.docs = docs
	local changes = {}
	for _, d in ipairs(docs) do
		if d.status then
			changes[#changes + 1] = { doc = d, depth = 0 }
		end
	end
	table.sort(changes, function(a, b)
		return by_title(a.doc, b.doc)
	end)
	state.rows.working = build_tree(working_docs(docs))
	state.rows.changes = changes
	if state.query then
		state.rows.pages = vim.tbl_map(function(m)
			return { doc = m.doc, depth = 0, has_kids = false, lnum = m.lnum }
		end, store.search(docs, state.query))
	else
		state.rows.pages = build_tree(docs)
	end

	render_status(docs)
	render_rows("working", state.rows.working, "Press w on a page to add it here")
	if state.query then
		render_rows("pages", state.rows.pages, "No matches")
		set_title("pages", ("%s · /%s (%d)"):format(TITLES.pages, state.query, #state.rows.pages))
	else
		render_rows("pages", state.rows.pages, "No pages. Press s to sync or g to get one.")
		set_title("pages", TITLES.pages)
	end
	render_rows("changes", changes, "Nothing to publish ✓")
	set_title("changes", ("%s (%d)"):format(TITLES.changes, #changes))
	render_hints()

	for _, name in ipairs({ "working", "pages", "changes" }) do
		local target = 1
		for i, r in ipairs(state.rows[name]) do
			if r.doc.path == keep[name] then
				target = i
			end
		end
		pcall(vim.api.nvim_win_set_cursor, state.wins[name], { target, 0 })
	end
	update_preview()
end

-------------------------------------------------------------------------------
-- Focus, actions, lifecycle
-------------------------------------------------------------------------------

function M.focus(name)
	if not state then
		return
	end
	state.focus = name
	if LISTS[name] then
		state.last_list = name
	end
	for _, n in ipairs(PANELS) do
		if n ~= "hints" then
			vim.wo[state.wins[n]].winhighlight = n == name
					and "FloatBorder:NotionActiveBorder,FloatTitle:NotionActiveBorder"
				or ""
		end
	end
	vim.api.nvim_set_current_win(state.wins[name])
	update_preview()
end

local function cycle(step)
	local idx = 1
	for i, n in ipairs(CYCLE) do
		if n == state.focus then
			idx = i
		end
	end
	M.focus(CYCLE[(idx - 1 + step) % #CYCLE + 1])
end

function M.close()
	if not state then
		return
	end
	local s = state
	state = nil
	pcall(vim.api.nvim_del_augroup_by_name, "notion.ui")
	for _, win in pairs(s.wins) do
		pcall(vim.api.nvim_win_close, win, true)
	end
end

local function doc_buf(d)
	local buf = store.find_buf(d.path)
	if not buf then
		buf = vim.fn.bufadd(d.path)
		vim.fn.bufload(buf)
	end
	return buf
end

local function with_doc(fn)
	return function()
		local d = current_doc()
		if d then
			fn(d)
		end
	end
end

local function edit(d)
	local r = current_row()
	local lnum, query = r and r.doc == d and r.lnum, state.query
	M.close()
	vim.cmd.edit(vim.fn.fnameescape(d.path))
	if lnum then
		pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
		vim.cmd("normal! zz")
	end
	if query then
		-- `n` / `N` keep jumping between matches.
		vim.fn.setreg("/", store.query_pattern(query))
		vim.v.hlsearch = 1
	end
end

---@param query? string nil clears the search
local function set_query(query)
	query = query and vim.trim(query) or ""
	state.query = query ~= "" and query or nil
	M.refresh(true)
	pcall(vim.api.nvim_win_set_cursor, state.wins.pages, { 1, 0 })
	update_preview()
end

local function toggle_fold(want)
	local name = list_panel()
	local r = current_row(name)
	if (name ~= "pages" and name ~= "working") or not r or not r.has_kids then
		return
	end
	local id = r.doc.id
	if want == nil then
		want = not collapsed[id]
	end
	collapsed[id] = want or nil
	M.refresh()
end

local actions = {
	open = with_doc(edit),
	publish = with_doc(function(d)
		require("notion.sync").publish(doc_buf(d))
	end),
	pull = with_doc(function(d)
		if d.id then
			require("notion.sync").pull(doc_buf(d), false)
		end
	end),
	-- Live diff (Notion vs local) rendered in the preview panel.
	diff = with_doc(function(d)
		local title = "[0] Diff with Notion · " .. d.title
		local function pin(lines, ft)
			state.diff = { path = d.path, lines = lines, ft = ft or "markdown", title = title }
			update_preview()
		end
		if not d.id then
			return pin({ "", "  This is a draft. It has no Notion version yet.", "", "  Press `p` to publish it." })
		end
		pin({ "", "  Loading the current version from Notion…" })
		local req = {}
		state.diff.req = req
		local function still_wanted()
			return state and state.diff and state.diff.req == req
		end
		require("notion.async").run(function()
			local md = require("notion.markdown")
			local remote = md.render(require("notion.api").fetch_tree(d.id))
			if not still_wanted() then
				return
			end
			local u = vim.diff(remote .. "\n", d.body .. "\n", { result_type = "unified", ctxlen = 3 })
			if u == "" then
				pin({ "", "  ✓ No differences. Your local file matches Notion." })
			else
				local lines = { "--- Notion (live)", "+++ local" }
				vim.list_extend(lines, vim.split(vim.trim(u), "\n", { plain = true }))
				pin(lines, "diff")
			end
		end, function(err)
			if still_wanted() then
				pin({ "", "  Could not load the Notion version:", "", "  " .. tostring(err) })
			end
		end)
	end),
	split_diff = with_doc(function(d)
		if not d.id then
			return
		end
		edit(d)
		require("notion.sync").diff(vim.api.nvim_get_current_buf())
	end),
	browse = with_doc(function(d)
		if d.url then
			vim.ui.open(d.url)
		end
	end),
	sync = function()
		require("notion.sync").sync()
	end,
	search = function()
		local before = state.query
		M.focus("pages")
		require("notion.modal").input({
			prompt = "Search pages (title and content)",
			default = before,
			on_change = function(text)
				if state then
					set_query(text)
				end
			end,
		}, function(text)
			if state then
				set_query(text == nil and before or text)
			end
		end)
	end,
	get = function()
		require("notion.sync").get()
	end,
	sync_mode = function()
		local all = store.sync_all()
		local items = {
			{ value = true, label = "All pages shared with the integration" },
			{ value = false, label = "Only pages I already have" },
		}
		require("notion.modal").select(items, {
			title = "Sync mode",
			prompt = "What should sync (s) download for this folder?",
			detail = "“Only pages I already have” updates pulled pages and brings in new sub-pages under them; "
				.. "other new pages are skipped (add them with g). "
				.. "Saved for "
				.. vim.fn.fnamemodify(config.sync_dir(), ":~")
				.. ".",
			format_item = function(it)
				return it.label .. (it.value == all and "  (current)" or "")
			end,
		}, function(choice)
			if choice and state then
				store.set_sync_all(choice.value)
				M.refresh(true)
			end
		end)
	end,
	work = with_doc(function(d)
		store.set_working(d, not store.is_working(d))
		M.refresh(true)
	end),
	new = function()
		M.close()
		require("notion").new()
	end,
	help = function()
		show_preview(HELP, "markdown", "[0] Keys")
	end,
}

local function map_keys()
	local common = {
		q = M.close,
		["<Esc>"] = function()
			if state.diff then
				state.diff = nil
				update_preview()
			elseif state.query then
				set_query(nil)
			else
				M.close()
			end
		end,
		D = actions.split_diff,
		["<Tab>"] = function()
			cycle(1)
		end,
		["<S-Tab>"] = function()
			cycle(-1)
		end,
		["1"] = function()
			M.focus("status")
		end,
		["2"] = function()
			M.focus("working")
		end,
		["3"] = function()
			M.focus("pages")
		end,
		["4"] = function()
			M.focus("changes")
		end,
		["0"] = function()
			M.focus("preview")
		end,
		["<CR>"] = actions.open,
		e = actions.open,
		p = actions.publish,
		P = actions.pull,
		s = actions.sync,
		S = actions.sync_mode,
		d = actions.diff,
		n = actions.new,
		o = actions.browse,
		["/"] = actions.search,
		g = actions.get,
		w = actions.work,
		L = function()
			require("notion").login()
		end,
		r = M.refresh,
		["?"] = actions.help,
	}
	local fold = {
		["<Space>"] = function()
			toggle_fold()
		end,
		za = function()
			toggle_fold()
		end,
		h = function()
			toggle_fold(true)
		end,
		l = function()
			toggle_fold(false)
		end,
	}
	for _, name in ipairs({ "status", "working", "pages", "changes", "preview" }) do
		local keys = (name == "pages" or name == "working") and vim.tbl_extend("force", common, fold) or common
		for lhs, fn in pairs(keys) do
			vim.keymap.set("n", lhs, fn, { buffer = state.bufs[name], nowait = true, silent = true })
		end
	end
end

local function autocmds()
	local group = vim.api.nvim_create_augroup("notion.ui", { clear = true })
	local name_of = {}
	for name, win in pairs(state.wins) do
		name_of[win] = name
	end
	for _, name in ipairs({ "working", "pages", "changes" }) do
		vim.api.nvim_create_autocmd("CursorMoved", {
			group = group,
			buffer = state.bufs[name],
			callback = function()
				state.last_list = name
				update_preview()
			end,
		})
	end
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = function()
			local name = name_of[vim.api.nvim_get_current_win()]
			if name and name ~= state.focus then
				M.focus(name)
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(ev)
			if name_of[tonumber(ev.match)] then
				vim.schedule(M.close)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			local cfgs = layout()
			for name, win in pairs(state.wins) do
				vim.api.nvim_win_set_config(win, cfgs[name])
			end
			M.refresh()
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = { "NotionSynced", "NotionPublished", "NotionPulled", "NotionLogin", "NotionWorking" },
		callback = function()
			if state then
				state.diff = nil -- the live diff is stale now
			end
			vim.schedule(M.refresh)
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = "*.md",
		callback = function()
			vim.schedule(M.refresh)
		end,
	})
end

function M.open()
	if state then
		return M.focus("pages")
	end
	set_hl()
	state = { wins = {}, bufs = {}, rows = { working = {}, pages = {}, changes = {} }, focus = "pages" }
	local cfgs = layout()
	for _, name in ipairs(PANELS) do
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "wipe"
		if name ~= "preview" then
			vim.bo[buf].filetype = "notion_" .. name
		end
		local cfg = cfgs[name]
		if TITLES[name] then
			cfg.title, cfg.title_pos = " " .. TITLES[name] .. " ", "left"
		end
		local win = vim.api.nvim_open_win(buf, false, cfg)
		vim.wo[win].cursorline = LISTS[name] or false
		vim.wo[win].wrap = name == "preview"
		state.bufs[name], state.wins[name] = buf, win
	end
	map_keys()
	autocmds()
	M.refresh()
	M.focus(#state.rows.working > 0 and "working" or "pages")
end

function M.toggle()
	if state then
		M.close()
	else
		M.open()
	end
end

return M
