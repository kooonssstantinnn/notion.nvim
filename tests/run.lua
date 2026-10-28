-- Run with: nvim --headless -u NONE -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

-- Never touch the real login files.
local config = require("notion.config")
local auth_dir = vim.fn.tempname()
config.auth_file = function()
	return auth_dir .. "/auth.json"
end
config.legacy_token_file = function()
	return auth_dir .. "/token"
end

local md = require("notion.markdown")
local diff = require("notion.diff")

local failures, passed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. "\n  " .. tostring(err) .. "\n")
	end
end

local function eq(a, b, msg)
	if not vim.deep_equal(a, b) then
		error((msg or "") .. "\nexpected: " .. vim.inspect(b) .. "\n     got: " .. vim.inspect(a), 2)
	end
end

local function roundtrip(src)
	return md.render(md.parse(src))
end

---------------------------------------------------------------------------
-- Markdown round trips (render(parse(x)) == x for canonical markdown)
---------------------------------------------------------------------------

local canonical = {
	headings = "# One\n\n## Two\n\n### Three",
	paragraph = "Hello **bold** *italic* ~~strike~~ `code` <u>under</u> **_both_** [link](https://x.y)",
	multiline_paragraph = "line one\nline two",
	lists = "- a\n- b\n  - nested\n    - deeper\n- c\n\n1. one\n2. two\n   1. sub\n\n- [ ] todo\n- [x] done",
	quote = "> quoted\n> second line",
	callout = "> [!NOTE] 💡\n> careful now",
	code = "```lua\nlocal x = 1\n\nprint(x)\n```",
	code_plain = "```\nplain\n```",
	divider = "above\n\n---\n\nbelow",
	equation = "$$\nE = mc^2\n$$",
	inline_eq = "mass $E=mc^2$ costs $5",
	table = "| a | b |\n| --- | --- |\n| 1 | 2 \\| 3 |",
	image = "![cap](https://img.example/x.png)",
	toggle = "▸ Click me\n  hidden text",
	empty_para = "a\n\n\nb",
	empty_paras = "a\n\n\n\nb\n\n- x\n\n\n- y",
	keep = "<!-- notion:keep 1234 child_page: Sub -->",
	escapes = "\\# not heading\n\\- not list\n1\\. not number\n2 \\* 3 and \\[x\\]",
	unicode = "Привіт **світ** 🎉",
	heading_children = "## Section\n  child paragraph",
	link_styles = "[**bold link**](https://a.b) and snake_case_word",
}

for name, src in pairs(canonical) do
	test("roundtrip: " .. name, function()
		eq(roundtrip(src), src)
	end)
end

test("parse: block types", function()
	local blocks = md.parse("# H\n\npara\n\n- item\n\n```py\nx\n```\n\n---")
	eq(
		vim.tbl_map(function(b)
			return b.type
		end, blocks),
		{ "heading_1", "paragraph", "bulleted_list_item", "code", "divider" }
	)
	eq(blocks[4].code.language, "python")
end)

test("parse: annotations", function()
	local rt = md.md_to_rich_text("a **b** *c*")
	eq(#rt, 4)
	eq(rt[2].text.content, "b")
	eq(rt[2].annotations.bold, true)
	eq(rt[4].annotations.italic, true)
end)

test("parse: adjacent italic and bold", function()
	local rt = md.md_to_rich_text("*x***y**")
	eq(rt[1].text.content, "x")
	eq(rt[1].annotations.italic, true)
	eq(rt[2].text.content, "y")
	eq(rt[2].annotations.bold, true)
end)

test("render: Notion API blocks", function()
	local blocks = {
		{
			id = "1",
			type = "paragraph",
			paragraph = {
				rich_text = {
					{ type = "text", plain_text = "Hi ", text = { content = "Hi " }, annotations = { bold = false } },
					{
						type = "mention",
						plain_text = "Other page",
						href = "https://www.notion.so/abc",
						annotations = {},
					},
				},
			},
		},
		{ id = "2", type = "child_page", child_page = { title = "Sub" } },
		{ id = "3", type = "image", image = { type = "file", file = { url = "https://s3/x" } } },
		{ id = "4", type = "bulleted_list_item", bulleted_list_item = { rich_text = {}, color = "red" } },
	}
	eq(
		md.render(blocks),
		"Hi [Other page](https://www.notion.so/abc)\n\n<!-- notion:keep 2 child_page: Sub -->\n\n<!-- notion:keep 3 image -->\n\n- "
	)
end)

test("rich text is chunked under the 2000 char limit", function()
	local rt = md.md_to_rich_text(("x"):rep(2500))
	eq(#rt, 3)
end)

---------------------------------------------------------------------------
-- Diff planning
---------------------------------------------------------------------------

local function remote_from(src)
	local blocks = md.parse(src)
	for i, b in ipairs(blocks) do
		b.id = "r" .. i
	end
	return blocks
end

test("plan: no changes", function()
	local p = diff.plan(remote_from("a\n\nb"), md.parse("a\n\nb"))
	eq(#p.deletes, 0)
	eq(p.inserted, 0)
end)

test("plan: edit in middle keeps neighbours", function()
	local p = diff.plan(remote_from("a\n\nb\n\nc"), md.parse("a\n\nB!\n\nc"))
	eq(p.deletes, { "r2" })
	eq(#p.groups, 1)
	eq(p.groups[1].after, "r1")
	eq(p.rewrite, false)
end)

test("plan: append at end", function()
	local p = diff.plan(remote_from("a"), md.parse("a\n\nb\n\nc"))
	eq(#p.deletes, 0)
	eq(p.groups[1].after, "r1")
	eq(#p.groups[1].blocks, 2)
end)

test("plan: insert at top forces rewrite", function()
	local p = diff.plan(remote_from("a\n\nb"), md.parse("z\n\na\n\nb"))
	eq(p.rewrite, true)
	eq(p.deletes, { "r1", "r2" })
	eq(p.inserted, 3)
end)

test("plan: keep blocks are never deleted while referenced", function()
	local remote = remote_from("a")
	table.insert(remote, { id = "kp", type = "child_page", child_page = { title = "S" } })
	local p = diff.plan(remote, md.parse("a changed\n\n<!-- notion:keep kp child_page: S -->"))
	eq(p.deletes, { "r1" })
	eq(p.rewrite, true) -- new first block has to go before the kept child page
	local p2 = diff.plan(remote, md.parse("a\n\n<!-- notion:keep kp child_page: S -->\n\nnew"))
	eq(#p2.deletes, 0)
	eq(p2.groups[1].after, "kp")
end)

---------------------------------------------------------------------------
-- End-to-end publish against a fake API
---------------------------------------------------------------------------

test("publish: diff applied through API", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, confirm_publish = false, notify_on_save = false, token = "t" })
	local api = require("notion.api")
	local store = require("notion.store")

	local page_id = "11111111-2222-3333-4444-555555555555"
	local remote = remote_from("Intro\n\nOld paragraph\n\nOutro")
	local calls = {}
	api.get_page = function()
		return {
			id = page_id,
			url = "https://notion.so/p",
			last_edited_time = "2026-01-01T00:00:00.000Z",
			properties = { Name = { type = "title", title = { { plain_text = "Doc" } } } },
		}
	end
	api.fetch_tree = function()
		return remote
	end
	api.delete_block = function(id)
		calls[#calls + 1] = "delete " .. id
	end
	api.append_children = function(_, children, after)
		calls[#calls + 1] = ("append %d after %s"):format(#children, after)
		local res = {}
		for i = 1, #children do
			res[i] = { id = "new" .. i }
		end
		return { results = res }
	end
	api.set_title = function(_, t)
		calls[#calls + 1] = "title " .. t
	end

	local path = dir .. "/Doc.md"
	store.write(path, { notion_id = page_id, title = "Doc" }, "Intro\n\nOld paragraph\n\nOutro")
	store.set_entry(page_id, { path = path, title = "Doc", last_edited = "2026-01-01T00:00:00.000Z", hash = "x" })

	vim.cmd.edit(path)
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, l in ipairs(lines) do
		if l == "Old paragraph" then
			lines[i] = "New **paragraph**"
		end
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	require("notion.sync").publish(buf)
	eq(calls, { "append 1 after r1", "delete r2" })
	eq(store.buf_status(buf), "published")
	vim.cmd("bwipeout!")
end)

---------------------------------------------------------------------------
-- Empty blocks <-> blank lines
---------------------------------------------------------------------------

local function types(blocks)
	return vim.tbl_map(function(b)
		return md.is_empty_paragraph(b) and "empty" or b.type
	end, blocks)
end

test("empty blocks: each extra blank line is one empty block", function()
	eq(types(md.parse("a\n\nb")), { "paragraph", "paragraph" })
	eq(types(md.parse("a\n\n\nb")), { "paragraph", "empty", "paragraph" })
	eq(types(md.parse("a\n\n\n\nb")), { "paragraph", "empty", "empty", "paragraph" })
	eq(types(md.parse("\n\na\n\n\n\n")), { "paragraph" })
end)

test("empty blocks: legacy <br> lines still parse", function()
	eq(types(md.parse("a\n\n<br>\n\nb")), { "paragraph", "empty", "paragraph" })
	eq(roundtrip("a\n\n<br>\n\nb"), "a\n\n\nb")
end)

test("empty blocks: leading/trailing ones from Notion are not written", function()
	local blocks = md.parse("a\n\n\nb")
	table.insert(blocks, 1, md.parse("x\n\n\ny")[2])
	table.insert(blocks, md.parse("x\n\n\ny")[2])
	eq(#blocks, 5)
	eq(md.render(blocks), "a\n\n\nb")
end)

test("plan: trailing empty block kept, new content goes before it", function()
	local remote = remote_from("a\n\n\n\n\nzz")
	table.remove(remote) -- remote = a, empty, empty (trailing)
	remote[#remote].id = "trail"
	remote[2].id = "trail0"
	local p = diff.plan(remote, md.parse("a\n\nb"))
	eq(p.deletes, {})
	eq(p.groups[1].after, "r1")
	eq(#p.groups[1].blocks, 1)
end)

test("plan: removing a blank line deletes that empty block", function()
	local p = diff.plan(remote_from("a\n\n\nb"), md.parse("a\n\nb"))
	eq(p.deletes, { "r2" })
	eq(p.inserted, 0)
end)

test("plan: adding a blank line creates an empty block", function()
	local p = diff.plan(remote_from("a\n\nb"), md.parse("a\n\n\nb"))
	eq(p.deletes, {})
	eq(p.groups[1].after, "r1")
	eq(md.is_empty_paragraph(p.groups[1].blocks[1]), true)
end)

test("plan: leading empty block anchors content inserted at the top", function()
	local remote = remote_from("x\n\n\na")
	table.remove(remote, 1) -- remote = empty (leading), a
	local p = diff.plan(remote, md.parse("new\n\na"))
	eq(p.rewrite, false)
	eq(p.deletes, {})
	eq(p.groups[1].after, "r2")
end)

---------------------------------------------------------------------------
-- Sub-pages added/renamed in Notion after the last sync
---------------------------------------------------------------------------

local function child_page(id, title)
	return { id = id, type = "child_page", child_page = { title = title } }
end

test("plan: sub-page added in Notion is never deleted", function()
	local remote = remote_from("Some notes")
	table.insert(remote, child_page("A", "Page 1"))
	table.insert(remote, child_page("B", "some"))
	local locals = md.parse("Some notes\n\n<!-- notion:keep A child_page: nvim1 -->")
	local p = diff.plan(remote, locals, { A = true })
	eq(p.deletes, {})
	eq(p.protected, 1)
	-- without a base snapshot nothing unrepresentable may be deleted either
	eq(diff.plan(remote, locals, nil).deletes, {})
end)

test("plan: sub-page line removed by the user is deleted", function()
	local remote = remote_from("Some notes")
	table.insert(remote, child_page("A", "x"))
	table.insert(remote, child_page("B", "y"))
	local p = diff.plan(remote, md.parse("Some notes\n\n<!-- notion:keep A child_page: x -->"), { A = true, B = true })
	eq(p.deletes, { "B" })
end)

test("sync: parent re-pulled when its sub-pages changed", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, notify_on_save = false, token = "t" })
	local api, store, sync = require("notion.api"), require("notion.store"), require("notion.sync")
	local P, A, B =
		"p0000000-0000-0000-0000-000000000000",
		"a0000000-0000-0000-0000-000000000000",
		"b0000000-0000-0000-0000-000000000000"
	local T = "2026-01-01T00:00:00.000Z"
	local function pg(id, title, parent)
		return {
			id = id,
			url = "u",
			last_edited_time = T,
			parent = parent and { type = "page_id", page_id = parent } or { type = "workspace" },
			properties = { title = { type = "title", title = { { plain_text = title } } } },
		}
	end
	-- state after an old sync: P contains sub-page A called "nvim1"
	local old = "Some notes\n\n<!-- notion:keep " .. A .. " child_page: nvim1 -->"
	store.write(dir .. "/test.md", { notion_id = P, title = "test" }, old)
	store.save_base(P, old)
	store.set_entry(P, { path = dir .. "/test.md", title = "test", last_edited = T, hash = store.hash(old) })
	store.write(dir .. "/nvim1.md", { notion_id = A, title = "nvim1" }, "")
	store.save_base(A, "")
	store.set_entry(
		A,
		{ path = dir .. "/nvim1.md", title = "nvim1", parent_id = P, last_edited = T, hash = store.hash("") }
	)

	-- in Notion: A renamed to "Page 1", B added; P's last_edited_time unchanged
	local fetched = {}
	api.search_pages = function()
		return { pg(P, "test"), pg(A, "Page 1", P), pg(B, "some", P) }
	end
	api.fetch_tree = function(id)
		fetched[#fetched + 1] = id
		if id == P then
			return { remote_from("Some notes")[1], child_page(A, "Page 1"), child_page(B, "some") }
		end
		return {}
	end
	sync.sync()
	local _, body = store.read(dir .. "/test.md")
	eq(
		body,
		"Some notes\n\n<!-- notion:keep "
			.. A
			.. " child_page: Page 1 -->\n\n<!-- notion:keep "
			.. B
			.. " child_page: some -->"
	)
	eq(vim.tbl_contains(fetched, P), true)
	eq(sync.children_stale(P), false)
end)

---------------------------------------------------------------------------
-- Links Notion would reject
---------------------------------------------------------------------------

test("links: resolved to URLs Notion accepts", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, token = "t" })
	local store, sync = require("notion.store"), require("notion.sync")
	store.set_entry(
		"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
		{ path = dir .. "/Other page.md", url = "https://www.notion.so/Other-aaa" }
	)
	local r = sync.resolve_link
	eq(r("https://neovim.io", dir), "https://neovim.io")
	eq(r("<https://neovim.io>", dir), "https://neovim.io")
	eq(r("mailto:a@b.c", dir), "mailto:a@b.c")
	eq(r("www.example.com", dir), "https://www.example.com")
	eq(r("/40655f83faaa8125a628fefb50f0c288", dir), "https://www.notion.so/40655f83faaa8125a628fefb50f0c288")
	eq(r("Other%20page.md#intro", dir), "https://www.notion.so/Other-aaa")
	eq(r("./Other page.md", dir), "https://www.notion.so/Other-aaa")
	eq(r("#heading", dir), nil)
	eq(r("Missing.md", dir), nil)
	eq(r("not a url", dir), nil)
	eq(r("https://…", dir), nil)
	eq(r("https://", dir), nil)
	eq(r("https://localhost", dir), nil)
	eq(r("https://sub.example.co.uk/a?b=1#c", dir), "https://sub.example.co.uk/a?b=1#c")
end)

test("links: relative Notion links render as full URLs", function()
	local rt =
		{ { type = "text", plain_text = "p", text = { content = "p", link = { url = "/abc" } }, annotations = {} } }
	eq(md.rich_text_to_md(rt), "[p](https://www.notion.so/abc)")
end)

test("publish: bad link becomes plain text instead of failing", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, confirm_publish = false, notify_on_save = false, token = "t" })
	local api, store = require("notion.api"), require("notion.store")
	local id = "22222222-2222-2222-2222-222222222222"
	local sent
	api.get_page = function()
		return {
			id = id,
			url = "u",
			last_edited_time = "1",
			properties = { title = { type = "title", title = { { plain_text = "L" } } } },
		}
	end
	api.fetch_tree = function()
		return {}
	end
	api.append_children = function(_, children)
		sent = children
		return { results = { { id = "n1" } } }
	end
	local path = dir .. "/L.md"
	store.write(path, { notion_id = id, title = "L" }, "see [this](#somewhere) and [site](https://x.y)")
	store.set_entry(id, { path = path, last_edited = "1" })
	vim.cmd.edit(path)
	require("notion.sync").publish(0)
	local rt = sent[1].paragraph.rich_text
	eq(rt[2].text.content, "this")
	eq(rt[2].text.link, nil)
	eq(rt[4].text.link.url, "https://x.y")
	vim.cmd("bwipeout!")
end)

---------------------------------------------------------------------------
-- Per-folder login
---------------------------------------------------------------------------

test("auth: logins are per folder", function()
	local a, b = vim.fn.tempname(), vim.fn.tempname()
	local env = vim.env.NOTION_TOKEN
	vim.env.NOTION_TOKEN = nil
	config.setup({ sync_dir = a })
	config.save_folder_auth({ token = "tok-a", name = "Bot A" })
	eq(config.token(), "tok-a")
	config.setup({ sync_dir = b })
	eq(config.token(), nil)
	config.save_folder_auth({ token = "tok-b" })
	eq(config.token(), "tok-b")
	config.setup({ sync_dir = a })
	eq(config.token(), "tok-a")
	config.remove_folder_auth()
	eq(config.token(), nil)
	config.setup({ sync_dir = b })
	eq(config.token(), "tok-b")
	-- token option and env var still work as overrides / fallbacks
	config.setup({ sync_dir = a, token = "opt" })
	eq(config.token(), "opt")
	vim.env.NOTION_TOKEN = "envtok"
	config.setup({ sync_dir = a })
	eq(config.token(), "envtok")
	vim.env.NOTION_TOKEN = env
	local perms = vim.uv.fs_stat(config.auth_file()).mode % 512
	eq(perms, 384) -- 0600
end)

test("auth: old global login moves to the first folder", function()
	vim.fn.delete(auth_dir, "rf")
	vim.fn.mkdir(auth_dir, "p")
	vim.fn.writefile({ "legacy" }, config.legacy_token_file())
	local env = vim.env.NOTION_TOKEN
	vim.env.NOTION_TOKEN = nil
	local a = vim.fn.tempname()
	config.setup({ sync_dir = a })
	eq(config.token(), "legacy")
	eq(vim.fn.filereadable(config.legacy_token_file()), 0)
	config.setup({ sync_dir = vim.fn.tempname() })
	eq(config.token(), nil)
	vim.env.NOTION_TOKEN = env
end)

---------------------------------------------------------------------------
-- Titles
---------------------------------------------------------------------------

test("titles: newlines from Notion become spaces", function()
	local api = require("notion.api")
	local page = {
		properties = {
			Name = { type = "title", title = { { plain_text = "Boards\nGuide" }, { plain_text = "\n" } } },
		},
	}
	eq(select(2, api.page_title(page)), "Boards Guide")
end)

test("titles: NUL-mangled frontmatter from older versions reads as one line", function()
	local store = require("notion.store")
	local fm = store.split({ "---", "title: Boards Guide\n", "---", "", "body" })
	eq(fm.title, "Boards Guide")
end)

test("paths: pages with the same title and ID prefix get separate files", function()
	local store = require("notion.store")
	config.setup({ sync_dir = vim.fn.tempname() })
	store.reset()
	local seen = {}
	for _, id in ipairs({
		"387acbe7-7225-8022-94b0-f2db97b6c911",
		"387acbe7-7225-8022-94b0-f2db97b6c922",
		"387acbe7-7225-8022-94b0-f2db97b6c933",
	}) do
		local path = store.new_path("Edit step", id)
		assert(not seen[path], "duplicate path " .. path)
		seen[path] = true
		store.write(path, { notion_id = id, title = "Edit step" }, "")
		store.set_entry(id, { path = path })
	end
end)

test("paths: a file linked to another page is not reused", function()
	local store = require("notion.store")
	config.setup({ sync_dir = vim.fn.tempname() })
	store.reset()
	local path = config.sync_dir() .. "/Shared.md"
	store.write(path, { notion_id = "387acbe7-7225-8022-94b0-f2db97b6c911" }, "")
	eq(store.owns("387acbe7-7225-8022-94b0-f2db97b6c911", path), true)
	eq(store.owns("387acbe7-7225-8022-94b0-f2db97b6c922", path), false)
	eq(store.owns("387acbe7-7225-8022-94b0-f2db97b6c922", path .. ".missing"), true)
end)

---------------------------------------------------------------------------
-- Search, Working, targeted pulls
---------------------------------------------------------------------------

test("search: all words must match, title hits first, smartcase", function()
	local store = require("notion.store")
	local docs = {
		{ title = "Zeta notes", body = "intro\n\nthe Billing flow\nend", body_start = 6, path = "z" },
		{ title = "Billing", body = "flow chart", body_start = 6, path = "b" },
		{ title = "Other", body = "billing only", body_start = 6, path = "o" },
	}
	local res = store.search(docs, "billing flow")
	eq(
		vim.tbl_map(function(m)
			return m.doc.path
		end, res),
		{ "b", "z" }
	)
	eq(res[2].lnum, 8) -- third body line
	eq(#store.search(docs, "Billing"), 2) -- uppercase: case-sensitive
	eq(#store.search(docs, "   "), 0)
	eq(vim.fn.match("x Billing y", store.query_pattern("billing")), 2)
end)

test("working: drafts by path, pages by id, kept in the index", function()
	local store = require("notion.store")
	local dir = vim.fn.tempname()
	config.setup({ sync_dir = dir })
	store.reset()
	local draft = { path = dir .. "/Draft.md" }
	local page = { id = "11111111-2222-3333-4444-555555555555", path = dir .. "/Page.md" }
	store.set_working(draft, true)
	store.set_working(page, true)
	store.reset()
	eq(store.index().working, { "Draft.md", page.id })
	eq(store.is_working(draft), true)
	-- once published, the draft is still found by its path
	eq(store.is_working({ id = "99999999-2222-3333-4444-555555555555", path = draft.path }), true)
	store.set_working(page, false)
	eq(store.is_working(page), false)
end)

test("get: pulls a page with nested sub-pages and adds it to Working", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, notify_on_save = false, token = "t", sync_all = false })
	local api, store, sync = require("notion.api"), require("notion.store"), require("notion.sync")
	local R, A, B, X =
		"10000000-0000-0000-0000-000000000000",
		"a0000000-0000-0000-0000-000000000000",
		"b0000000-0000-0000-0000-000000000000",
		"f0000000-0000-0000-0000-000000000000"
	local function pg(id, title, parent)
		return {
			id = id,
			url = "u",
			last_edited_time = "2026-01-01T00:00:00.000Z",
			parent = parent and { type = "page_id", page_id = parent } or { type = "workspace" },
			properties = { title = { type = "title", title = { { plain_text = title } } } },
		}
	end
	local C, D = "c0000000-0000-0000-0000-000000000000", "d0000000-0000-0000-0000-000000000000"
	local pages = { [R] = pg(R, "Root"), [A] = pg(A, "A", R), [B] = pg(B, "B", A), [X] = pg(X, "Elsewhere") }
	api.get_page = function(id)
		return pages[id]
	end
	api.fetch_tree = function(id)
		if id == R then
			return { child_page(A, "A") }
		elseif id == A then
			return { child_page(B, "B") }
		end
		return {}
	end
	sync.get("https://www.notion.so/Root-" .. R:gsub("-", ""), true)
	for _, id in ipairs({ R, A, B }) do
		assert(store.entry(id), "not pulled: " .. id)
	end
	eq(store.entry(X), nil)
	eq(store.index().working, { R })

	-- sync_all = false: sync leaves pages you never pulled alone,
	-- but new sub-pages (and their sub-pages) under pages you have come along
	pages[C] = pg(C, "New under A", A)
	pages[D] = pg(D, "New under C", C)
	api.search_pages = function()
		return vim.tbl_values(pages)
	end
	sync.sync()
	eq(store.entry(X), nil)
	assert(store.entry(C) and store.entry(D), "new sub-pages not pulled")
	eq(store.entry(D).parent_id, C)
end)

test("ui: dashboard opens with Working, search and closes", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, notify_on_save = false, token = "t" })
	local store, ui = require("notion.store"), require("notion.ui")
	store.write(dir .. "/One.md", { title = "One\n" }, "hello world")
	store.write(dir .. "/Two.md", { title = "Two" }, "other text")
	store.set_working({ path = dir .. "/One.md" }, true)
	ui.open()
	vim.api.nvim_feedkeys("w", "x", false) -- focus starts on Working: removes One
	eq(store.is_working({ path = dir .. "/One.md" }), false)
	ui.refresh()
	ui.close()
end)

test("titles: modal choices and old index titles with newlines", function()
	local store = require("notion.store")
	local dir = vim.fn.tempname()
	config.setup({ sync_dir = dir })
	vim.fn.mkdir(dir, "p")
	vim.fn.writefile(
		{ vim.json.encode({ pages = { x = { path = "X.md", title = "Boards Guide\n" } } }) },
		dir .. "/.notion-index.json"
	)
	store.reset()
	eq(store.entry("x").title, "Boards Guide")
	local picked
	require("notion.modal").select({ "a\nb", "c" }, {}, function(it)
		picked = it
	end)
	eq(vim.api.nvim_get_current_line(), "    a b")
	vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
	vim.wait(100, function()
		return picked ~= nil
	end)
	eq(picked, "a\nb")
end)

test("index: changes from another Neovim are not overwritten", function()
	local store = require("notion.store")
	local dir = vim.fn.tempname()
	config.setup({ sync_dir = dir })
	store.reset()
	store.set_entry("a", { path = dir .. "/A.md", title = "A" })
	-- another instance adds a page to Working and saves the whole index
	local path = dir .. "/.notion-index.json"
	local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	data.working = { "a" }
	vim.fn.writefile({ vim.json.encode(data) }, path)
	-- this instance saves something else afterwards
	store.set_entry("b", { path = dir .. "/B.md", title = "B" })
	store.reset()
	eq(store.index().working, { "a" })
	eq(store.entry("b").title, "B")
end)

test("sync mode: per-folder choice overrides the sync_all option", function()
	local store = require("notion.store")
	config.setup({ sync_dir = vim.fn.tempname(), sync_all = false })
	store.reset()
	eq(store.sync_all(), false)
	store.set_sync_all(true)
	store.reset()
	eq(store.sync_all(), true)
	config.setup({ sync_dir = vim.fn.tempname() })
	store.reset()
	eq(store.sync_all(), true)
end)

test("sync: pages deleted in Notion are removed locally, edited ones kept", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, notify_on_save = false, token = "t" })
	local api, store, sync = require("notion.api"), require("notion.store"), require("notion.sync")
	local T = "2026-01-01T00:00:00.000Z"
	local function id(c)
		return c .. ("0"):rep(7) .. "-0000-0000-0000-000000000000"
	end
	local function pg(i, extra)
		return vim.tbl_extend("force", {
			id = i,
			url = "u",
			last_edited_time = T,
			parent = { type = "workspace" },
			properties = { title = { type = "title", title = { { plain_text = i:sub(1, 1) } } } },
		}, extra or {})
	end
	local live, deleted, trashed, edited, lagging = id("1"), id("2"), id("3"), id("4"), id("5")
	for _, i in ipairs({ live, deleted, trashed, edited, lagging }) do
		local path = dir .. "/" .. i:sub(1, 1) .. ".md"
		store.write(path, { notion_id = i }, "body")
		store.save_base(i, "body")
		store.set_entry(i, { path = path, title = i:sub(1, 1), last_edited = T, hash = store.hash("body") })
	end
	store.set_working({ id = deleted }, true)
	store.write(dir .. "/4.md", { notion_id = edited }, "my local edit")

	api.search_pages = function()
		return { pg(live), pg(trashed, { in_trash = true }) }
	end
	api.find_page = function(i)
		if i == trashed then
			return pg(trashed, { in_trash = true })
		elseif i == lagging then
			return pg(lagging) -- missing from search, but still exists
		end
		return nil -- 404
	end
	api.fetch_tree = function()
		return {}
	end
	sync.sync()

	eq(store.entry(deleted), nil)
	eq(store.entry(trashed), nil)
	eq(vim.fn.filereadable(dir .. "/2.md"), 0)
	eq(vim.fn.filereadable(dir .. "/3.md"), 0)
	eq(store.read_base(deleted), nil)
	eq(store.is_working({ id = deleted }), false)
	assert(store.entry(edited) and vim.fn.filereadable(dir .. "/4.md") == 1, "edited page removed")
	assert(store.entry(lagging) and store.entry(live), "live page removed")
end)

test("sync: removing most pages asks first", function()
	local dir = vim.fn.tempname()
	require("notion").setup({ sync_dir = dir, notify_on_save = false, token = "t" })
	local api, store, sync, async =
		require("notion.api"), require("notion.store"), require("notion.sync"), require("notion.async")
	for n = 10, 21 do
		local i = ("%08d-0000-0000-0000-000000000000"):format(n)
		store.write(dir .. "/" .. n .. ".md", { notion_id = i }, "")
		store.set_entry(i, { path = dir .. "/" .. n .. ".md", title = tostring(n), hash = store.hash("") })
	end
	api.search_pages = function()
		return {}
	end
	api.find_page = function()
		return nil
	end
	local asked, confirm = false, async.confirm
	async.confirm = function()
		asked = true
		return false
	end
	sync.sync()
	async.confirm = confirm
	eq(asked, true)
	eq(vim.tbl_count(store.index().pages), 12)
end)

io.stdout:write(("%d passed, %d failed\n"):format(passed, failures))
os.exit(failures == 0 and 0 or 1)
