-- Small centered floating dialogs used for confirmations, choices and text input.
local M = {}

local ns = vim.api.nvim_create_namespace("notion.modal")

local function set_hl()
	local function link(name, to)
		vim.api.nvim_set_hl(0, name, { link = to, default = true })
	end
	link("NotionModalSelected", "PmenuSel")
	link("NotionModalBorder", "DiagnosticOk")
	link("NotionKey", "Function")
	link("NotionDim", "Comment")
end

local function wrap(text, width)
	local out = {}
	for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
		local line = ""
		for word in para:gmatch("%S+") do
			if line == "" then
				line = word
			elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
				line = line .. " " .. word
			else
				out[#out + 1] = line
				line = word
			end
		end
		out[#out + 1] = line
	end
	return out
end

local function open_float(buf, width, height, title, footer)
	local cfg = {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "rounded",
		style = "minimal",
		zindex = 100,
		title = " " .. title .. " ",
		title_pos = "center",
		footer = footer and (" " .. footer .. " ") or nil,
		footer_pos = footer and "center" or nil,
	}
	local win = vim.api.nvim_open_win(buf, true, cfg)
	vim.wo[win].winhighlight = "FloatBorder:NotionModalBorder,FloatTitle:NotionModalBorder,FloatFooter:NotionDim"
	return win
end

---Create a one-shot finisher: closes the window, restores focus, calls cb once.
local function finisher(win, prev, cb)
	local done = false
	return function(...)
		if done then
			return
		end
		done = true
		pcall(vim.api.nvim_win_close, win, true)
		if vim.api.nvim_win_is_valid(prev) then
			vim.api.nvim_set_current_win(prev)
		end
		local args = vim.F.pack_len(...)
		vim.schedule(function()
			cb(vim.F.unpack_len(args))
		end)
	end
end

local function close_on_leave(buf, finish)
	vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		buffer = buf,
		once = true,
		callback = function()
			finish(nil)
		end,
	})
end

---Same contract as vim.ui.select. Extra opts: `title` (window title), `detail` (dim text below the prompt).
function M.select(items, opts, cb)
	opts = opts or {}
	set_hl()
	local fmt = opts.format_item or tostring
	local labels = vim.tbl_map(fmt, items)

	-- First free letter of each label becomes its hotkey.
	local hotkeys, used = {}, { j = true, k = true, q = true }
	for i, label in ipairs(labels) do
		for pos = 1, #label do
			local ch = label:sub(pos, pos):lower()
			if ch:match("%a") and not used[ch] then
				hotkeys[i], used[ch] = { key = ch, col = pos - 1 }, true
				break
			end
		end
	end

	local max_label = 0
	for _, l in ipairs(labels) do
		max_label = math.max(max_label, vim.fn.strdisplaywidth(l))
	end
	local width = math.min(math.max(44, max_label + 8), math.max(44, math.floor(vim.o.columns * 0.6)))
	local text = width - 4

	local lines, marks = { "" }, {}
	for _, l in ipairs(wrap(opts.prompt, text)) do
		lines[#lines + 1] = "  " .. l
	end
	if opts.detail and opts.detail ~= "" then
		for _, l in ipairs(wrap(opts.detail, text)) do
			lines[#lines + 1] = "  " .. l
			marks[#marks + 1] = { #lines - 1, "NotionDim" }
		end
	end
	lines[#lines + 1] = ""
	local first_item = #lines + 1
	for _, l in ipairs(labels) do
		lines[#lines + 1] = "    " .. l
	end
	lines[#lines + 1] = ""

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	for _, m in ipairs(marks) do
		vim.api.nvim_buf_set_extmark(buf, ns, m[1], 0, { end_row = m[1] + 1, hl_group = m[2], hl_eol = false })
	end
	for i, hk in pairs(hotkeys) do
		local row = first_item + i - 2
		vim.api.nvim_buf_set_extmark(buf, ns, row, 4 + hk.col, { end_col = 5 + hk.col, hl_group = "NotionKey" })
	end

	local height = math.min(#lines, math.max(6, vim.o.lines - 6))
	local prev = vim.api.nvim_get_current_win()
	local win = open_float(buf, width, height, opts.title or "Notion", "⏎ select · esc cancel")
	local finish = finisher(win, prev, cb)

	local sel = 1
	local sel_ns = vim.api.nvim_create_namespace("notion.modal.sel")
	local function render()
		vim.api.nvim_buf_clear_namespace(buf, sel_ns, 0, -1)
		local row = first_item + sel - 2
		vim.api.nvim_buf_set_extmark(buf, sel_ns, row, 0, { line_hl_group = "NotionModalSelected" })
		vim.api.nvim_buf_set_extmark(
			buf,
			sel_ns,
			row,
			0,
			{ virt_text = { { "  ›", "NotionKey" } }, virt_text_pos = "overlay" }
		)
		vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
	end
	local function move(d)
		sel = (sel - 1 + d) % #items + 1
		render()
	end
	local function choose(i)
		if items[i] ~= nil then
			finish(items[i], i)
		end
	end

	local function map(lhs, fn)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
	end
	for _, k in ipairs({ "j", "<Down>", "<Tab>", "<C-n>" }) do
		map(k, function()
			move(1)
		end)
	end
	for _, k in ipairs({ "k", "<Up>", "<S-Tab>", "<C-p>" }) do
		map(k, function()
			move(-1)
		end)
	end
	map("<CR>", function()
		choose(sel)
	end)
	for _, k in ipairs({ "q", "<Esc>", "<C-c>" }) do
		map(k, function()
			finish(nil, nil)
		end)
	end
	for i = 1, math.min(#items, 9) do
		map(tostring(i), function()
			choose(i)
		end)
	end
	for i, hk in pairs(hotkeys) do
		map(hk.key, function()
			choose(i)
		end)
	end
	map("<LeftRelease>", function()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		local i = row - first_item + 1
		if items[i] ~= nil then
			choose(i)
		else
			render()
		end
	end)

	close_on_leave(buf, function()
		finish(nil, nil)
	end)
	render()
end

---Same contract as vim.ui.input.
function M.input(opts, cb)
	opts = opts or {}
	set_hl()
	local width = math.min(60, math.max(40, math.floor(vim.o.columns * 0.5)))
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default or "" })
	local title = vim.trim((opts.prompt or "Input"):gsub(":%s*$", ""))
	local prev = vim.api.nvim_get_current_win()
	local win = open_float(buf, width, 1, title, "⏎ confirm · esc cancel")
	local finish = finisher(win, prev, function(value)
		vim.cmd("stopinsert")
		cb(value)
	end)

	local function submit()
		finish(vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""))
	end
	local function cancel()
		finish(nil)
	end
	for _, mode in ipairs({ "i", "n" }) do
		vim.keymap.set(mode, "<CR>", submit, { buffer = buf, nowait = true })
		vim.keymap.set(mode, "<Esc>", cancel, { buffer = buf, nowait = true })
		vim.keymap.set(mode, "<C-c>", cancel, { buffer = buf, nowait = true })
	end
	vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true })
	close_on_leave(buf, cancel)
	vim.cmd("startinsert!")
end

return M
