local config = require("notion.config")

local M = {}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Notion" })
end

local function store()
	return require("notion.store")
end

local function sync()
	return require("notion.sync")
end

local augroup = vim.api.nvim_create_augroup("notion.nvim", { clear = true })

function M.setup(opts)
	config.setup(opts)
	store().reset()

	vim.api.nvim_clear_autocmds({ group = augroup })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = augroup,
		pattern = "*.md",
		callback = function(ev)
			if not config.options.notify_on_save or vim.b[ev.buf].notion_save_hint then
				return
			end
			local status = store().buf_status(ev.buf)
			if status == "modified" or status == "new" then
				vim.b[ev.buf].notion_save_hint = true
				notify("Saved locally. Run :Notion publish when you're ready to push it to Notion.")
			end
		end,
	})

	if config.options.sync_on_startup and config.token() then
		vim.defer_fn(function()
			sync().sync()
		end, 500)
	end
end

---Log in for the current folder only. The token is checked before it is saved.
function M.login()
	local dir = config.sync_dir()
	local where = vim.fn.fnamemodify(dir, ":~")
	local token = vim.trim(vim.fn.inputsecret(("Notion integration secret for %s: "):format(where)) or "")
	if token == "" then
		return
	end
	require("notion.async").run(function()
		local me = require("notion.api").me(token)
		local workspace = me.bot and me.bot.workspace_name or nil
		config.save_folder_auth({ token = token, name = me.name, workspace = workspace }, dir)
		vim.api.nvim_exec_autocmds("User", { pattern = "NotionLogin" })
		notify(
			("Logged in to %s as “%s” for %s. Run :Notion sync to download your pages."):format(
				workspace or "Notion",
				me.name or "integration",
				where
			)
		)
	end, function(err)
		notify("Login failed, token not saved: " .. tostring(err), vim.log.levels.ERROR)
	end)
end

function M.logout()
	local dir = config.sync_dir()
	if not config.folder_auth(dir) then
		notify("Not logged in for " .. vim.fn.fnamemodify(dir, ":~"), vim.log.levels.WARN)
		return
	end
	config.remove_folder_auth(dir)
	vim.api.nvim_exec_autocmds("User", { pattern = "NotionLogin" })
	notify("Logged out for " .. vim.fn.fnamemodify(dir, ":~"))
end

function M.open()
	local items = {}
	for id, e in pairs(store().index().pages) do
		if e.path and vim.uv.fs_stat(e.path) then
			items[#items + 1] = { id = id, title = e.title or "Untitled", path = e.path }
		end
	end
	if #items == 0 then
		notify("No synced pages yet. Run :Notion sync first.", vim.log.levels.WARN)
		return
	end
	table.sort(items, function(a, b)
		return a.title:lower() < b.title:lower()
	end)
	vim.ui.select(items, {
		prompt = "Notion pages",
		format_item = function(it)
			local _, body = store().read(it.path)
			local e = store().entry(it.id)
			local dirty = e and body and e.hash ~= store().hash(body)
			return (dirty and "● " or "  ") .. it.title
		end,
	}, function(choice)
		if choice then
			vim.cmd.edit(vim.fn.fnameescape(choice.path))
		end
	end)
end

function M.new(title)
	local function create(t)
		t = vim.trim(t or "")
		if t == "" then
			return
		end
		local path = store().new_path(t)
		store().write(path, { title = t, parent = config.options.default_parent }, "")
		store().set_working({ path = path }, true)
		vim.cmd.edit(vim.fn.fnameescape(path))
		vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
		notify("New draft. It stays local until you run :Notion publish.")
	end
	if title and title ~= "" then
		create(title)
	else
		require("notion.modal").input({ prompt = "New page title" }, create)
	end
end

function M.publish(buf)
	sync().publish(buf or vim.api.nvim_get_current_buf())
end

function M.pull(buf, force)
	sync().pull(buf or vim.api.nvim_get_current_buf(), force)
end

function M.sync()
	sync().sync()
end

---Pull one page by URL, ID or title. `with_children`: true/false, nil = ask.
function M.get(input, with_children)
	sync().get(input, with_children)
end

---Quickfix list of lines matching `query` in pulled docs (all words must be in the doc).
function M.search(query)
	if not query or vim.trim(query) == "" then
		require("notion.modal").input({ prompt = "Search pulled pages" }, function(q)
			if q and q ~= "" then
				M.search(q)
			end
		end)
		return
	end
	local words, icase = store().parse_query(query)
	local items = {}
	for _, m in ipairs(store().search(store().docs(), query)) do
		local lines = store().doc_lines(m.doc.path) or {}
		local found = false
		for lnum = m.doc.body_start or 1, #lines do
			local line = icase and lines[lnum]:lower() or lines[lnum]
			for _, w in ipairs(words) do
				if line:find(icase and w:lower() or w, 1, true) then
					items[#items + 1] =
						{ filename = m.doc.path, lnum = lnum, text = m.doc.title .. ": " .. vim.trim(lines[lnum]) }
					found = true
					break
				end
			end
		end
		if not found then
			items[#items + 1] = { filename = m.doc.path, lnum = 1, text = m.doc.title .. " (title)" }
		end
	end
	if #items == 0 then
		notify(("No pulled page matches “%s”"):format(query), vim.log.levels.WARN)
		return
	end
	vim.fn.setqflist({}, " ", { title = "Notion: " .. query, items = items })
	vim.fn.setreg("/", store().query_pattern(query))
	vim.cmd("copen")
end

---Add the current buffer's doc to Working, or remove it.
function M.work(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local path = vim.api.nvim_buf_get_name(buf)
	local fm = store().split(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	local doc = { id = store().normalize_id(fm.notion_id), path = path ~= "" and path or nil }
	if not doc.id and not doc.path then
		notify("Save this buffer to a file first", vim.log.levels.WARN)
		return
	end
	local on = not store().is_working(doc)
	store().set_working(doc, on)
	vim.api.nvim_exec_autocmds("User", { pattern = "NotionWorking", data = { doc = doc, working = on } })
	notify(on and "Added to Working" or "Removed from Working")
end

function M.diff(buf)
	sync().diff(buf or vim.api.nvim_get_current_buf())
end

function M.status()
	sync().status()
end

function M.browse(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	local fm = store().split(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	local id = store().normalize_id(fm.notion_id)
	local e = id and store().entry(id)
	local url = fm.url or (e and e.url)
	if not url then
		notify("This buffer is not published to Notion yet", vim.log.levels.WARN)
		return
	end
	vim.ui.open(url)
end

---Statusline component: "" for non-Notion buffers.
function M.statusline()
	local status = store().buf_status(vim.api.nvim_get_current_buf())
	if status == "published" then
		return "Notion ✓"
	elseif status == "modified" then
		return "Notion ●"
	elseif status == "new" then
		return "Notion ＋"
	end
	return ""
end

function M.ui()
	require("notion.ui").toggle()
end

M.commands = {
	ui = function()
		M.ui()
	end,
	login = function()
		M.login()
	end,
	logout = function()
		M.logout()
	end,
	sync = function()
		M.sync()
	end,
	get = function(args, bang)
		M.get(args, bang or nil)
	end,
	search = function(args)
		M.search(args)
	end,
	work = function()
		M.work()
	end,
	open = function()
		M.open()
	end,
	new = function(args)
		M.new(args)
	end,
	publish = function()
		M.publish()
	end,
	pull = function(_, bang)
		M.pull(nil, bang)
	end,
	diff = function()
		M.diff()
	end,
	status = function()
		M.status()
	end,
	browse = function()
		M.browse()
	end,
}

function M.command(opts)
	local sub, rest = (opts.args or ""):match("^(%S*)%s*(.-)$")
	sub = sub ~= "" and sub or "ui"
	local fn = M.commands[sub]
	if not fn then
		notify("Unknown subcommand: " .. sub, vim.log.levels.ERROR)
		return
	end
	fn(rest, opts.bang)
end

return M
