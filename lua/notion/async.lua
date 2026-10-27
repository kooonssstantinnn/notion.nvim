-- Minimal coroutine helpers so API code can be written top-to-bottom.
local M = {}

local steps = setmetatable({}, { __mode = "k" })

---Run `fn` as a coroutine. Errors are reported with vim.notify.
---@param fn function
---@param on_error? fun(err: string)
function M.run(fn, on_error)
	local co = coroutine.create(fn)
	local function step(...)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			vim.schedule(function()
				if on_error then
					on_error(err)
				else
					vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Notion" })
				end
			end)
		end
	end
	steps[co] = step
	step()
end

---Wait for a callback-style function: `start(cb)`. Returns the values passed to cb.
function M.await(start)
	local co = coroutine.running()
	assert(co and steps[co], "notion.nvim: await() called outside of async.run()")
	local results, yielded = nil, false
	start(function(...)
		if yielded then
			steps[co](...)
		else
			results = vim.F.pack_len(...)
		end
	end)
	if results then
		return vim.F.unpack_len(results)
	end
	yielded = true
	return coroutine.yield()
end

function M.sleep(ms)
	M.await(function(cb)
		vim.defer_fn(cb, ms)
	end)
end

---Centered modal choice (see notion.modal.select for opts).
---@return any item, integer? idx
function M.select(items, opts)
	return M.await(function(cb)
		vim.schedule(function()
			require("notion.modal").select(items, opts, cb)
		end)
	end)
end

---@return string?
function M.input(opts)
	return M.await(function(cb)
		vim.schedule(function()
			require("notion.modal").input(opts, cb)
		end)
	end)
end

---Yes/cancel confirmation. `opts` may set `title` and `detail`.
function M.confirm(prompt, yes, opts)
	yes = yes or "Yes"
	local choice = M.select({ yes, "Cancel" }, vim.tbl_extend("force", opts or {}, { prompt = prompt }))
	return choice == yes
end

return M
