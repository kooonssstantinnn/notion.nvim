-- Conversion between Notion blocks and markdown.
--
-- Blocks that can't be represented in markdown (child pages, databases, columns,
-- uploaded files, synced blocks, ...) are rendered as
--   <!-- notion:keep <block-id> <type> -->
-- and left untouched in Notion on publish as long as that line stays in the file.
local M = {}

local LANGS = {}
for _, l in ipairs({
	"abap",
	"arduino",
	"bash",
	"basic",
	"c",
	"clojure",
	"coffeescript",
	"c++",
	"c#",
	"css",
	"dart",
	"diff",
	"docker",
	"elixir",
	"elm",
	"erlang",
	"flow",
	"fortran",
	"f#",
	"gherkin",
	"glsl",
	"go",
	"graphql",
	"groovy",
	"haskell",
	"html",
	"java",
	"javascript",
	"json",
	"julia",
	"kotlin",
	"latex",
	"less",
	"lisp",
	"livescript",
	"lua",
	"makefile",
	"markdown",
	"markup",
	"matlab",
	"mermaid",
	"nix",
	"objective-c",
	"ocaml",
	"pascal",
	"perl",
	"php",
	"plain text",
	"powershell",
	"prolog",
	"protobuf",
	"python",
	"r",
	"reason",
	"ruby",
	"rust",
	"sass",
	"scala",
	"scheme",
	"scss",
	"shell",
	"sql",
	"swift",
	"typescript",
	"vb.net",
	"verilog",
	"vhdl",
	"visual basic",
	"webassembly",
	"xml",
	"yaml",
	"java/c/c++/c#",
}) do
	LANGS[l] = true
end

local LANG_ALIASES = {
	js = "javascript",
	jsx = "javascript",
	ts = "typescript",
	tsx = "typescript",
	py = "python",
	sh = "shell",
	zsh = "shell",
	console = "shell",
	yml = "yaml",
	md = "markdown",
	rb = "ruby",
	rs = "rust",
	cpp = "c++",
	cxx = "c++",
	cs = "c#",
	csharp = "c#",
	fsharp = "f#",
	dockerfile = "docker",
	golang = "go",
	text = "plain text",
	txt = "plain text",
	plaintext = "plain text",
	[""] = "plain text",
	objc = "objective-c",
	kt = "kotlin",
	ps1 = "powershell",
	proto = "protobuf",
	tex = "latex",
	vb = "visual basic",
	hs = "haskell",
	ex = "elixir",
	exs = "elixir",
	ml = "ocaml",
	jl = "julia",
	wasm = "webassembly",
	make = "makefile",
	gql = "graphql",
}

local CALLOUT_ICONS =
	{ NOTE = "💡", TIP = "💡", INFO = "ℹ️", WARNING = "⚠️", IMPORTANT = "❗", CAUTION = "🚫" }

local SUPPORTED = {
	paragraph = true,
	heading_1 = true,
	heading_2 = true,
	heading_3 = true,
	bulleted_list_item = true,
	numbered_list_item = true,
	to_do = true,
	toggle = true,
	quote = true,
	callout = true,
	code = true,
	divider = true,
	equation = true,
	table = true,
	image = true,
}

local CAN_HAVE_CHILDREN = {
	paragraph = true,
	heading_1 = true,
	heading_2 = true,
	heading_3 = true,
	bulleted_list_item = true,
	numbered_list_item = true,
	to_do = true,
	toggle = true,
	quote = true,
	callout = true,
}

local LIST = { bulleted_list_item = true, numbered_list_item = true, to_do = true }

function M.is_supported(b)
	if b.type == "image" then
		return b.image ~= nil and b.image.type == "external"
	end
	return SUPPORTED[b.type] == true
end

local function split_lines(s)
	return vim.split(s, "\n", { plain = true })
end

-------------------------------------------------------------------------------
-- Rich text -> markdown
-------------------------------------------------------------------------------

local STYLE_KEYS = { "bold", "italic", "strike", "underline", "code" }

local function same_style(a, b)
	for _, k in ipairs(STYLE_KEYS) do
		if (a[k] or false) ~= (b[k] or false) then
			return false
		end
	end
	return a.link == b.link
end

---Normalize Notion rich text (API response or our own request objects) into style runs.
local function to_runs(rich_text)
	local runs = {}
	for _, rt in ipairs(rich_text or {}) do
		local a = rt.annotations or {}
		local run = {
			bold = a.bold or false,
			italic = a.italic or false,
			strike = a.strikethrough or false,
			underline = a.underline or false,
			code = a.code or false,
		}
		if rt.type == "equation" then
			run.equation = true
			run.text = (rt.equation and rt.equation.expression) or rt.plain_text or ""
		else
			run.text = (rt.type == "text" and rt.text and rt.text.content) or rt.plain_text or ""
			run.link = rt.href or (rt.text and rt.text.link and rt.text.link.url) or nil
			if run.link and run.link:sub(1, 1) == "/" then
				run.link = "https://www.notion.so" .. run.link -- internal page links are relative
			end
		end
		local prev = runs[#runs]
		if prev and not prev.equation and not run.equation and same_style(prev, run) then
			prev.text = prev.text .. run.text
		elseif run.text ~= "" then
			runs[#runs + 1] = run
		end
	end
	return runs
end

local function escape(s)
	local out = {}
	for i = 1, #s do
		local c = s:sub(i, i)
		local pv, nx = s:sub(i - 1, i - 1), s:sub(i + 1, i + 1)
		if c == "\\" or c == "*" or c == "`" or c == "[" or c == "]" then
			c = "\\" .. c
		elseif c == "~" and (nx == "~" or pv == "~") then
			c = "\\~"
		elseif c == "$" and nx ~= "" and not nx:match("[%s%d]") then
			c = "\\$"
		elseif c == "_" and not pv:match("%w") and nx ~= "" and not nx:match("%s") then
			c = "\\_"
		elseif c == "<" and (s:sub(i, i + 3) == "<br>" or s:sub(i, i + 2) == "<u>") then
			c = "\\<"
		end
		out[#out + 1] = c
	end
	return table.concat(out)
end

local function render_run(r)
	local text = r.text
	if r.equation then
		return "$" .. text .. "$"
	end
	local lead, core, trail = text:match("^(%s*)(.-)(%s*)$")
	if core == "" then
		return text
	end
	if r.code then
		local ticks = "`"
		while core:find(ticks, 1, true) do
			ticks = ticks .. "`"
		end
		local pad = (core:sub(1, 1) == "`" or core:sub(-1) == "`") and " " or ""
		core = ticks .. pad .. core .. pad .. ticks
	else
		core = escape(core)
	end
	if r.underline then
		core = "<u>" .. core .. "</u>"
	end
	if r.strike then
		core = "~~" .. core .. "~~"
	end
	if r.bold and r.italic then
		core = "**_" .. core .. "_**"
	elseif r.bold then
		core = "**" .. core .. "**"
	elseif r.italic then
		core = "*" .. core .. "*"
	end
	if r.link then
		core = "[" .. core .. "](" .. r.link .. ")"
	end
	return lead .. core .. trail
end

---@param br? boolean render newlines as <br> (for single-line constructs)
function M.rich_text_to_md(rich_text, br)
	local parts = {}
	for _, r in ipairs(to_runs(rich_text)) do
		parts[#parts + 1] = render_run(r)
	end
	local s = table.concat(parts)
	if br then
		s = s:gsub("\n", "<br>")
	end
	return s
end

local function plain(rich_text)
	local parts = {}
	for _, rt in ipairs(rich_text or {}) do
		parts[#parts + 1] = (rt.text and rt.text.content) or rt.plain_text or ""
	end
	return table.concat(parts)
end

-------------------------------------------------------------------------------
-- Markdown -> rich text
-------------------------------------------------------------------------------

local function with(st, k, v)
	local n = vim.deepcopy(st)
	n[k] = v == nil and true or v
	return n
end

---Find a backtick run of exactly `len` starting at or after `from`.
local function find_ticks(s, len, from)
	local ticks = ("`"):rep(len)
	while true do
		local j = s:find(ticks, from, true)
		if not j then
			return nil
		end
		if s:sub(j + len, j + len) ~= "`" and s:sub(j - 1, j - 1) ~= "`" then
			return j
		end
		from = j + 1
	end
end

---Advance past an escape or code span at i; returns the new index or nil if nothing to skip.
local function skip(s, i)
	local c = s:sub(i, i)
	if c == "\\" then
		return i + 2
	elseif c == "`" then
		local ticks = s:match("^`+", i)
		local j = find_ticks(s, #ticks, i + #ticks)
		return j and (j + #ticks) or (i + #ticks)
	end
end

local function find_close(s, i, delim)
	while i <= #s do
		local nxt = skip(s, i)
		if nxt then
			i = nxt
		elseif s:sub(i, i + #delim - 1) == delim then
			return i
		else
			i = i + 1
		end
	end
end

-- `want` is 1 (italic) or 2 (bold). A run of stars of odd length can close italic,
-- any run of 2+ can close bold (remaining stars open the next span).
local function find_star_close(s, i, want)
	while i <= #s do
		local nxt = skip(s, i)
		if nxt then
			i = nxt
		elseif s:sub(i, i) == "*" then
			local len = #s:match("^%*+", i)
			if (want == 2 and len >= 2) or (want == 1 and len % 2 == 1) then
				return i
			end
			i = i + len
		else
			i = i + 1
		end
	end
end

local function find_underscore_close(s, i)
	while i <= #s do
		local nxt = skip(s, i)
		if nxt then
			i = nxt
		elseif s:sub(i, i) == "_" and not s:sub(i + 1, i + 1):match("%w") and not s:sub(i - 1, i - 1):match("%s") then
			return i
		else
			i = i + 1
		end
	end
end

local function find_bracket_close(s, i)
	local depth = 1
	while i <= #s do
		local nxt = skip(s, i)
		if nxt then
			i = nxt
		else
			local c = s:sub(i, i)
			if c == "[" then
				depth = depth + 1
			elseif c == "]" then
				depth = depth - 1
				if depth == 0 then
					return i
				end
			end
			i = i + 1
		end
	end
end

local TOGGLE = "▸"

local function parse_inline(s, st, out)
	st, out = st or {}, out or {}
	local buf = {}
	local function flush()
		if #buf > 0 then
			local run = vim.deepcopy(st)
			run.text = table.concat(buf)
			out[#out + 1] = run
			buf = {}
		end
	end
	local function span(inner, style)
		flush()
		parse_inline(inner, style, out)
	end

	local i, n = 1, #s
	while i <= n do
		local c = s:sub(i, i)
		local two = s:sub(i, i + 1)
		local handled = false

		if c == "\\" then
			local nx = s:sub(i + 1, i + 1)
			if nx:match("%p") then
				buf[#buf + 1] = nx
				i, handled = i + 2, true
			elseif s:sub(i + 1, i + #TOGGLE) == TOGGLE then
				buf[#buf + 1] = TOGGLE
				i, handled = i + 1 + #TOGGLE, true
			end
		elseif c == "`" then
			local ticks = s:match("^`+", i)
			local j = find_ticks(s, #ticks, i + #ticks)
			if j then
				local content = s:sub(i + #ticks, j - 1)
				if #content > 2 and content:sub(1, 1) == " " and content:sub(-1) == " " then
					content = content:sub(2, -2)
				end
				flush()
				local run = with(st, "code")
				run.text = content
				out[#out + 1] = run
				i = j + #ticks
			else
				buf[#buf + 1] = ticks
				i = i + #ticks
			end
			handled = true
		elseif two == "**" then
			local j = find_star_close(s, i + 2, 2)
			if j and j > i + 2 then
				span(s:sub(i + 2, j - 1), with(st, "bold"))
				i, handled = j + 2, true
			end
		elseif c == "*" and not s:sub(i + 1, i + 1):match("%s") then
			local j = find_star_close(s, i + 1, 1)
			if j and j > i + 1 then
				span(s:sub(i + 1, j - 1), with(st, "italic"))
				i, handled = j + 1, true
			end
		elseif c == "_" and not s:sub(i - 1, i - 1):match("%w") and not s:sub(i + 1, i + 1):match("%s") then
			local j = find_underscore_close(s, i + 1)
			if j and j > i + 1 then
				span(s:sub(i + 1, j - 1), with(st, "italic"))
				i, handled = j + 1, true
			end
		elseif two == "~~" then
			local j = find_close(s, i + 2, "~~")
			if j and j > i + 2 then
				span(s:sub(i + 2, j - 1), with(st, "strike"))
				i, handled = j + 2, true
			end
		elseif s:sub(i, i + 2) == "<u>" then
			local j = find_close(s, i + 3, "</u>")
			if j then
				span(s:sub(i + 3, j - 1), with(st, "underline"))
				i, handled = j + 4, true
			end
		elseif s:sub(i, i + 3) == "<br>" then
			buf[#buf + 1] = "\n"
			i, handled = i + 4, true
		elseif c == "[" then
			local j = find_bracket_close(s, i + 1)
			if j and s:sub(j + 1, j + 1) == "(" then
				local k = s:find(")", j + 2, true)
				if k then
					span(s:sub(i + 1, j - 1), with(st, "link", s:sub(j + 2, k - 1)))
					i, handled = k + 1, true
				end
			end
		elseif c == "$" then
			local nx = s:sub(i + 1, i + 1)
			if nx ~= "" and not nx:match("[%s%d$]") then
				local j = find_close(s, i + 1, "$")
				if j and not s:sub(j - 1, j - 1):match("%s") and not s:sub(j + 1, j + 1):match("%d") then
					flush()
					local run = vim.deepcopy(st)
					run.text, run.equation = s:sub(i + 1, j - 1), true
					out[#out + 1] = run
					i, handled = j + 1, true
				end
			end
		end

		if not handled then
			buf[#buf + 1] = c
			i = i + 1
		end
	end
	flush()
	return out
end

---Split a string into chunks of at most `size` characters (UTF-8 aware).
local function chunks(s, size)
	local out = {}
	local nchars = vim.fn.strchars(s)
	if nchars <= size then
		return { s }
	end
	for start = 0, nchars - 1, size do
		out[#out + 1] = vim.fn.strcharpart(s, start, size)
	end
	return out
end

local function text_obj(content, ann, link)
	local obj = { type = "text", text = { content = content }, annotations = ann }
	if link then
		obj.text.link = { url = link }
	end
	return obj
end

function M.md_to_rich_text(s)
	local runs = parse_inline(s)
	local merged = {}
	for _, r in ipairs(runs) do
		local prev = merged[#merged]
		if prev and not prev.equation and not r.equation and same_style(prev, r) then
			prev.text = prev.text .. r.text
		elseif r.text ~= "" then
			merged[#merged + 1] = r
		end
	end
	local out = {}
	for _, r in ipairs(merged) do
		local ann = {
			bold = r.bold or false,
			italic = r.italic or false,
			strikethrough = r.strike or false,
			underline = r.underline or false,
			code = r.code or false,
		}
		if r.equation then
			out[#out + 1] = { type = "equation", equation = { expression = r.text }, annotations = ann }
		else
			for _, chunk in ipairs(chunks(r.text, 1000)) do
				out[#out + 1] = text_obj(chunk, ann, r.link)
			end
		end
	end
	return out
end

local function plain_rich_text(s)
	local out = {}
	for _, chunk in ipairs(chunks(s, 1000)) do
		if chunk ~= "" then
			out[#out + 1] = { type = "text", text = { content = chunk } }
		end
	end
	return out
end

-------------------------------------------------------------------------------
-- Block classification (shared by renderer escaping and parser)
-------------------------------------------------------------------------------

local function is_table_sep(line)
	return line ~= nil and vim.trim(line):match("^|?%s*:?%-+:?%s*|") ~= nil
end

---@param t string line with leading indentation removed
local function classify(t)
	if t:match("^```") then
		return "fence"
	elseif t:match("^%$%$") then
		return "equation"
	elseif t:match("^#+%s") then
		return "heading"
	elseif t:match("^%-%-%-+%s*$") or t:match("^%*%*%*+%s*$") or t:match("^___+%s*$") then
		return "hr"
	elseif t:match("^[-*+]%s+%[[ xX]%]%s") or t:match("^[-*+]%s+%[[ xX]%]$") then
		return "todo"
	elseif t:match("^[-*+]%s") or t:match("^[-*+]$") then
		return "bullet"
	elseif t:match("^%d+[.)]%s") or t:match("^%d+[.)]$") then
		return "number"
	elseif t:match("^>") then
		return "quote"
	elseif t:match("^|") then
		return "table"
	elseif t:sub(1, #TOGGLE) == TOGGLE then
		return "toggle"
	elseif t:match("^<!%-%- notion:keep ") then
		return "keep"
	elseif t == "<br>" then
		return "br"
	elseif t:match("^!%[.-%]%(.-%)%s*$") then
		return "image"
	end
end

-- Paragraph lines that would be mistaken for another block get a leading escape.
local function escape_line_start(line)
	if line:match("^%d+[.)]%s") or line:match("^%d+[.)]$") then
		return (line:gsub("^(%d+)([.)])", "%1\\%2"))
	end
	if classify(line) then
		return "\\" .. line
	end
	return line
end

-------------------------------------------------------------------------------
-- Blocks -> markdown
-------------------------------------------------------------------------------

local function indent(text, pad)
	local lines = split_lines(text)
	for i, l in ipairs(lines) do
		if l ~= "" then
			lines[i] = pad .. l
		end
	end
	return table.concat(lines, "\n")
end

local function quote_lines(text)
	local out = {}
	for _, l in ipairs(split_lines(text)) do
		out[#out + 1] = l == "" and ">" or ("> " .. l)
	end
	return out
end

function M.keep_line(b)
	local label = b.type
	local data = b[b.type] or {}
	if data.title and data.title ~= "" then
		label = label .. ": " .. data.title
	end
	return ("<!-- notion:keep %s %s -->"):format(b.id, label)
end

local render_blocks

---A paragraph with no text and no children (a blank line in Notion).
function M.is_empty_paragraph(b)
	if b._keep or b.type ~= "paragraph" or not b.paragraph then
		return false
	end
	local d = b.paragraph
	if d.children and #d.children > 0 then
		return false
	end
	for _, rt in ipairs(d.rich_text or {}) do
		if rt.type == "equation" or ((rt.text and rt.text.content) or rt.plain_text or "") ~= "" then
			return false
		end
	end
	return true
end

local function render_block(b, num)
	if b._keep then
		return b._keep_line
	end
	if not M.is_supported(b) then
		return M.keep_line(b)
	end
	local t, d = b.type, b[b.type]
	local head
	local pad = "  "

	if t == "paragraph" then
		local s = M.rich_text_to_md(d.rich_text)
		if s == "" then
			-- only reached for keys, or for an empty paragraph that has children
			head = (d.children and #d.children > 0) and "<br>" or ""
		else
			local lines = split_lines(s)
			for i, l in ipairs(lines) do
				lines[i] = escape_line_start(l)
			end
			head = table.concat(lines, "\n")
		end
	elseif t == "heading_1" or t == "heading_2" or t == "heading_3" then
		head = ("#"):rep(tonumber(t:sub(-1))) .. " " .. M.rich_text_to_md(d.rich_text, true)
	elseif t == "bulleted_list_item" then
		head = "- " .. M.rich_text_to_md(d.rich_text, true)
	elseif t == "numbered_list_item" then
		head = num .. ". " .. M.rich_text_to_md(d.rich_text, true)
		pad = (" "):rep(#tostring(num) + 2)
	elseif t == "to_do" then
		head = (d.checked and "- [x] " or "- [ ] ") .. M.rich_text_to_md(d.rich_text, true)
	elseif t == "toggle" then
		head = TOGGLE .. " " .. M.rich_text_to_md(d.rich_text, true)
	elseif t == "quote" then
		head = table.concat(quote_lines(M.rich_text_to_md(d.rich_text)), "\n")
	elseif t == "callout" then
		local icon = d.icon and d.icon.type == "emoji" and d.icon.emoji
		local lines = { "> [!NOTE]" .. (icon and (" " .. icon) or "") }
		local text = M.rich_text_to_md(d.rich_text)
		if text ~= "" then
			vim.list_extend(lines, quote_lines(text))
		end
		head = table.concat(lines, "\n")
	elseif t == "code" then
		local content = plain(d.rich_text)
		local fence = "```"
		while content:find(fence, 1, true) do
			fence = fence .. "`"
		end
		local lang = (d.language == "plain text" or not d.language) and "" or d.language:gsub(" ", "_")
		head = fence .. lang .. "\n" .. content .. "\n" .. fence
	elseif t == "divider" then
		head = "---"
	elseif t == "equation" then
		head = "$$\n" .. (d.expression or "") .. "\n$$"
	elseif t == "table" then
		local rows = d.children or {}
		local width = d.table_width or (rows[1] and #rows[1].table_row.cells) or 1
		local function row_md(r)
			local cells = {}
			for c = 1, width do
				local cell = r.table_row and r.table_row.cells[c] or {}
				cells[c] = (M.rich_text_to_md(cell, true):gsub("|", "\\|"))
			end
			return "| " .. table.concat(cells, " | ") .. " |"
		end
		local lines = {}
		if #rows == 0 then
			lines[1] = "| " .. ("  | "):rep(width - 1) .. " |"
		else
			lines[1] = row_md(rows[1])
		end
		lines[2] = "|" .. (" --- |"):rep(width)
		for k = 2, #rows do
			lines[#lines + 1] = row_md(rows[k])
		end
		head = table.concat(lines, "\n")
	elseif t == "image" then
		head = "![" .. M.rich_text_to_md(d.caption, true) .. "](" .. d.external.url .. ")"
	end

	local kids = CAN_HAVE_CHILDREN[t] and d.children
	if kids and #kids > 0 then
		head = head .. "\n" .. indent(render_blocks(kids), pad)
	end
	return head
end

-- Empty paragraphs are written as extra blank lines: one blank line separates blocks,
-- each additional one is an empty block. Leading/trailing ones are not written (Notion
-- keeps a trailing empty block on most pages); publish leaves those untouched.
function render_blocks(blocks)
	local parts = {}
	local num, prev, empties = 0, nil, 0
	for _, b in ipairs(blocks) do
		if M.is_empty_paragraph(b) then
			if prev then
				empties = empties + 1
			end
		else
			if b.type == "numbered_list_item" then
				num = (prev and prev.type == "numbered_list_item" and empties == 0) and num + 1 or 1
			end
			if prev then
				if empties > 0 then
					parts[#parts + 1] = "\n\n" .. ("\n"):rep(empties)
				else
					parts[#parts + 1] = (LIST[b.type] and prev.type == b.type) and "\n" or "\n\n"
				end
			end
			parts[#parts + 1] = render_block(b, num)
			prev, empties = b, 0
		end
	end
	return table.concat(parts)
end

---Render a list of Notion blocks to a markdown string.
M.render = render_blocks

---Identity of a top-level block used to diff local vs remote content.
function M.key(b)
	if b._keep then
		return "keep:" .. b._keep
	end
	if not M.is_supported(b) then
		return "keep:" .. b.id
	end
	return render_block(b, 1)
end

-------------------------------------------------------------------------------
-- Markdown -> blocks
-------------------------------------------------------------------------------

local function is_blank(l)
	return l:match("^%s*$") ~= nil
end

local function indent_of(l)
	return #l:match("^ *")
end

local function dedent(lines)
	local min = math.huge
	for _, l in ipairs(lines) do
		if not is_blank(l) then
			min = math.min(min, indent_of(l))
		end
	end
	local out = {}
	for i, l in ipairs(lines) do
		out[i] = is_blank(l) and "" or l:sub(min + 1)
	end
	return out
end

local function blk(t, data)
	return { type = t, [t] = data }
end

local function split_row(t)
	local cells, cur, i = {}, {}, 1
	t = vim.trim(t)
	while i <= #t do
		local c = t:sub(i, i)
		if c == "\\" then
			cur[#cur + 1] = t:sub(i, i + 1)
			i = i + 2
		else
			if c == "|" then
				cells[#cells + 1] = table.concat(cur)
				cur = {}
			else
				cur[#cur + 1] = c
			end
			i = i + 1
		end
	end
	cells[#cells + 1] = table.concat(cur)
	if t:sub(1, 1) == "|" then
		table.remove(cells, 1)
	end
	if #cells > 0 and vim.trim(cells[#cells]) == "" and t:sub(-1) == "|" then
		table.remove(cells)
	end
	for k, c in ipairs(cells) do
		cells[k] = vim.trim(c)
	end
	return cells
end

local function normalize_lang(info)
	local lang = (info:match("^(%S*)") or ""):lower():gsub("_", " ")
	lang = LANG_ALIASES[lang] or lang
	return LANGS[lang] and lang or "plain text"
end

local parse_lines

---Parse one block starting at lines[i]. Returns block (or nil) and the next line index.
local function parse_block(lines, i, base, t)
	local n = #lines
	local kind = classify(t)
	if kind == "table" and not is_table_sep(lines[i + 1]) then
		kind = nil
	end

	local function stripped(k)
		local l = lines[k]
		return l:sub(indent_of(l) + 1)
	end

	if kind == "fence" then
		local fence = t:match("^`+")
		local content, j = {}, i + 1
		while j <= n and not stripped(j):match("^" .. fence .. "%s*$") do
			local l = lines[j]
			content[#content + 1] = l:sub(math.min(indent_of(l), base) + 1)
			j = j + 1
		end
		return blk("code", {
			rich_text = plain_rich_text(table.concat(content, "\n")),
			language = normalize_lang(t:sub(#fence + 1)),
		}),
			j + 1
	elseif kind == "equation" then
		local single = t:match("^%$%$(.+)%$%$%s*$")
		if single then
			return blk("equation", { expression = vim.trim(single) }), i + 1
		end
		local content, j = { t:sub(3) ~= "" and t:sub(3) or nil }, i + 1
		while j <= n and vim.trim(lines[j]) ~= "$$" do
			content[#content + 1] = stripped(j)
			j = j + 1
		end
		return blk("equation", { expression = table.concat(content, "\n") }), j + 1
	elseif kind == "heading" then
		local hashes, text = t:match("^(#+)%s+(.-)%s*$")
		local level = math.min(#hashes, 3)
		return blk("heading_" .. level, { rich_text = M.md_to_rich_text(text) }), i + 1
	elseif kind == "hr" then
		return blk("divider", vim.empty_dict()), i + 1
	elseif kind == "todo" then
		local mark, text = t:match("^[-*+]%s+%[([ xX])%]%s*(.*)$")
		return blk("to_do", { rich_text = M.md_to_rich_text(text), checked = mark ~= " " }), i + 1
	elseif kind == "bullet" then
		return blk("bulleted_list_item", { rich_text = M.md_to_rich_text(t:match("^[-*+]%s*(.*)$")) }), i + 1
	elseif kind == "number" then
		return blk("numbered_list_item", { rich_text = M.md_to_rich_text(t:match("^%d+[.)]%s*(.*)$")) }), i + 1
	elseif kind == "toggle" then
		return blk("toggle", { rich_text = M.md_to_rich_text(vim.trim(t:sub(#TOGGLE + 1))) }), i + 1
	elseif kind == "keep" then
		return { type = "_keep", _keep = t:match("^<!%-%- notion:keep (%S+)"), _keep_line = vim.trim(t) }, i + 1
	elseif kind == "br" then
		return blk("paragraph", { rich_text = {} }), i + 1
	elseif kind == "image" then
		local alt, url = t:match("^!%[(.-)%]%((.-)%)%s*$")
		return blk("image", { type = "external", external = { url = url }, caption = M.md_to_rich_text(alt) }), i + 1
	elseif kind == "quote" then
		local content, j = {}, i
		while j <= n and not is_blank(lines[j]) and stripped(j):match("^>") do
			content[#content + 1] = (stripped(j):gsub("^>%s?", ""))
			j = j + 1
		end
		local alert, icon = content[1]:match("^%[!(%a+)%]%s*(.-)%s*$")
		if alert then
			table.remove(content, 1)
			icon = icon ~= "" and icon or CALLOUT_ICONS[alert:upper()] or "💡"
			return blk("callout", {
				rich_text = M.md_to_rich_text(table.concat(content, "\n")),
				icon = { type = "emoji", emoji = icon },
			}),
				j
		end
		return blk("quote", { rich_text = M.md_to_rich_text(table.concat(content, "\n")) }), j
	elseif kind == "table" then
		local header = split_row(t)
		local width = #header
		local rows, j = {}, i + 2
		local function row(cells)
			local out = {}
			for c = 1, width do
				out[c] = M.md_to_rich_text(cells[c] or "")
			end
			return blk("table_row", { cells = out })
		end
		rows[1] = row(header)
		while j <= n and stripped(j):match("^|") do
			rows[#rows + 1] = row(split_row(stripped(j)))
			j = j + 1
		end
		return blk("table", {
			table_width = width,
			has_column_header = true,
			has_row_header = false,
			children = rows,
		}),
			j
	end

	-- paragraph
	local text, j = { t }, i + 1
	while j <= n and not is_blank(lines[j]) and indent_of(lines[j]) <= base do
		local tt = stripped(j)
		local k = classify(tt)
		if k and not (k == "table" and not is_table_sep(lines[j + 1])) then
			break
		end
		text[#text + 1] = tt
		j = j + 1
	end
	return blk("paragraph", { rich_text = M.md_to_rich_text(table.concat(text, "\n")) }), j
end

function parse_lines(lines)
	local blocks = {}
	local i, n = 1, #lines
	local blanks = 0
	while i <= n do
		if is_blank(lines[i]) then
			blanks = blanks + 1
			i = i + 1
		else
			-- each blank line beyond the first separator is an empty block
			if #blocks > 0 then
				for _ = 2, blanks do
					blocks[#blocks + 1] = blk("paragraph", { rich_text = {} })
				end
			end
			blanks = 0
			local base = indent_of(lines[i])
			local block, nexti = parse_block(lines, i, base, lines[i]:sub(base + 1))
			-- More-indented lines that follow become children.
			if CAN_HAVE_CHILDREN[block.type] then
				local j, last = nexti, nexti - 1
				while j <= n and (is_blank(lines[j]) or indent_of(lines[j]) > base) do
					if not is_blank(lines[j]) then
						last = j
					end
					j = j + 1
				end
				if last >= nexti then
					local sub = {}
					for k = nexti, last do
						sub[#sub + 1] = lines[k]
					end
					local d = block[block.type]
					d.children = parse_lines(dedent(sub))
					if block.type:match("^heading_") then
						d.is_toggleable = true
					end
					nexti = last + 1
				end
			end
			blocks[#blocks + 1] = block
			i = nexti
		end
	end
	return blocks
end

---Parse a markdown string into Notion block objects (request format).
function M.parse(text)
	local lines = split_lines((text:gsub("\r\n", "\n")))
	for i, l in ipairs(lines) do
		local lead = l:match("^[ \t]*")
		if lead:find("\t") then
			lines[i] = lead:gsub("\t", "    ") .. l:sub(#lead + 1)
		end
	end
	return parse_lines(lines)
end

return M
