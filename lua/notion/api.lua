-- Thin Notion REST client on top of curl + vim.system.
local async = require("notion.async")
local config = require("notion.config")

local M = {}

M.base_url = "https://api.notion.com/v1"
M.version = "2022-06-28"

local JSON_OPTS = { luanil = { object = true, array = true } }

---Build the curl invocation. The token goes through stdin (-K -) so it never shows up in `ps`.
function M._curl_args(method, path, body, token)
	local cmd = { "curl", "-sS", "-X", method, "-K", "-", "-w", "\n%{http_code}", M.base_url .. path }
	local tmp
	if body ~= nil then
		tmp = vim.fn.tempname()
		local f = assert(io.open(tmp, "wb"))
		f:write(vim.json.encode(body))
		f:close()
		vim.list_extend(cmd, { "--data-binary", "@" .. tmp })
	end
	local stdin = table.concat({
		('header = "Authorization: Bearer %s"'):format(token),
		('header = "Notion-Version: %s"'):format(M.version),
		'header = "Content-Type: application/json"',
		"",
	}, "\n")
	return cmd, stdin, tmp
end

---@return integer status, table? data, string raw
function M._parse(stdout)
	local out, status = (stdout or ""):match("^(.*)\n(%d+)$")
	local ok, data = pcall(vim.json.decode, out or "", JSON_OPTS)
	return tonumber(status) or 0, ok and data or nil, out or ""
end

---Perform a request. Must be called inside async.run(). Retries on 429/5xx.
---@param token? string defaults to the current folder's login
function M.request(method, path, body, token)
	token = token or config.token()
	if not token then
		error(
			("Not logged in to Notion for %s. Run :Notion login here."):format(
				vim.fn.fnamemodify(config.sync_dir(), ":~")
			),
			0
		)
	end
	local attempt = 0
	while true do
		attempt = attempt + 1
		local obj = async.await(function(cb)
			local cmd, stdin, tmp = M._curl_args(method, path, body, token)
			vim.system(cmd, { stdin = stdin, text = true }, function(res)
				if tmp then
					os.remove(tmp)
				end
				vim.schedule(function()
					cb(res)
				end)
			end)
		end)
		if obj.code ~= 0 then
			if attempt >= 4 then
				error("curl failed: " .. vim.trim(obj.stderr or ""), 0)
			end
			async.sleep(1000 * attempt)
		else
			local status, data, raw = M._parse(obj.stdout)
			if status >= 200 and status < 300 then
				return data or {}
			elseif (status == 429 or status >= 500) and attempt < 6 then
				async.sleep(math.min(1000 * 2 ^ (attempt - 1), 10000))
			else
				local msg = data and data.message or raw
				error(("Notion API %s %s failed (%d): %s"):format(method, path:gsub("%?.*", ""), status, msg), 0)
			end
		end
	end
end

local function paginate(fetch)
	local results, cursor = {}, nil
	repeat
		local res = fetch(cursor)
		vim.list_extend(results, res.results or {})
		cursor = res.has_more and res.next_cursor or nil
	until not cursor
	return results
end

---@param token? string check a specific token instead of the current login
function M.me(token)
	return M.request("GET", "/users/me", nil, token)
end

---All pages shared with the integration.
function M.search_pages()
	return paginate(function(cursor)
		return M.request("POST", "/search", {
			filter = { property = "object", value = "page" },
			page_size = 100,
			start_cursor = cursor,
		})
	end)
end

function M.get_page(id)
	return M.request("GET", "/pages/" .. id)
end

function M.list_children(id)
	return paginate(function(cursor)
		local q = "?page_size=100" .. (cursor and ("&start_cursor=" .. cursor) or "")
		return M.request("GET", "/blocks/" .. id .. "/children" .. q)
	end)
end

---Fetch a block tree; children of supported blocks are attached as block[type].children.
function M.fetch_tree(id)
	local md = require("notion.markdown")
	local blocks = M.list_children(id)
	for _, b in ipairs(blocks) do
		if b.has_children and md.is_supported(b) then
			b[b.type].children = M.fetch_tree(b.id)
		end
	end
	return blocks
end

function M.append_children(id, children, after)
	return M.request("PATCH", "/blocks/" .. id .. "/children", { children = children, after = after })
end

function M.delete_block(id)
	return M.request("DELETE", "/blocks/" .. id)
end

function M.create_page(parent_id, title)
	return M.request("POST", "/pages", {
		parent = { page_id = parent_id },
		properties = { title = { title = { { type = "text", text = { content = title } } } } },
	})
end

---@return string? name, string title
function M.page_title(page)
	for name, prop in pairs(page.properties or {}) do
		if prop.type == "title" then
			local parts = {}
			for _, rt in ipairs(prop.title or {}) do
				parts[#parts + 1] = rt.plain_text or ""
			end
			return name, table.concat(parts)
		end
	end
	return nil, ""
end

function M.set_title(page, title)
	local prop = M.page_title(page) or "title"
	return M.request("PATCH", "/pages/" .. page.id, {
		properties = { [prop] = { title = { { type = "text", text = { content = title } } } } },
	})
end

return M
