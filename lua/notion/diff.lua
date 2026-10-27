-- Plans the minimal set of top-level block deletes/inserts to turn the remote
-- page into the local document. Unchanged blocks keep their IDs (and comments).
local md = require("notion.markdown")

local M = {}

---@param remote table[] Notion blocks currently on the page (with children attached)
---@param locals table[] blocks parsed from the local markdown
---@param known? table<string, true> IDs of keep-blocks present at the last sync. A keep-block
---  (sub-page, database, file, ...) is only deleted if it was known and the user removed its
---  line. Ones added in Notion after the last sync are never deleted. Without `known`, none are.
---@return { deletes: string[], groups: { after: string?, blocks: table[] }[], inserted: integer, warnings: string[], rewrite: boolean, protected: integer }
function M.plan(remote, locals, known)
	local rk, lk = {}, {}
	for i, b in ipairs(remote) do
		rk[i] = md.key(b)
	end
	for i, b in ipairs(locals) do
		lk[i] = md.key(b)
	end

	-- Longest common subsequence over top-level block keys.
	local n, m = #rk, #lk
	local L = {}
	for i = n + 1, 1, -1 do
		L[i] = {}
		for j = m + 1, 1, -1 do
			if i > n or j > m then
				L[i][j] = 0
			elseif rk[i] == lk[j] then
				L[i][j] = L[i + 1][j + 1] + 1
			else
				L[i][j] = math.max(L[i + 1][j], L[i][j + 1])
			end
		end
	end

	-- Empty paragraphs before the first / after the last real block aren't in the
	-- markdown (see markdown.render), so they are left alone on publish.
	local first_real, last_real = nil, 0
	for k, b in ipairs(remote) do
		if not md.is_empty_paragraph(b) then
			first_real, last_real = first_real or k, k
		end
	end
	local edge, trailing = {}, {}
	for k, b in ipairs(remote) do
		if md.is_empty_paragraph(b) and (not first_real or k < first_real or k > last_real) then
			edge[b.id] = true
			trailing[k] = k > last_real
		end
	end

	local ops, i, j = {}, 1, 1
	while i <= n or j <= m do
		if i <= n and j <= m and rk[i] == lk[j] then
			ops[#ops + 1] = { kind = "match", remote = remote[i] }
			i, j = i + 1, j + 1
		else
			local can_delete = i <= n and (j > m or L[i + 1][j] >= L[i][j + 1])
			local can_insert = j <= m and (i > n or L[i][j + 1] >= L[i + 1][j])
			-- New content at the end goes before Notion's trailing empty block, not after it.
			if can_delete and not (can_insert and trailing[i]) then
				ops[#ops + 1] = { kind = "delete", remote = remote[i] }
				i = i + 1
			else
				ops[#ops + 1] = { kind = "insert", block = locals[j] }
				j = j + 1
			end
		end
	end

	local local_keeps, remote_ids = {}, {}
	for _, b in ipairs(locals) do
		if b._keep then
			local_keeps[b._keep] = true
		end
	end
	for _, b in ipairs(remote) do
		remote_ids[b.id] = true
	end
	local function protected(b)
		return local_keeps[b.id] or edge[b.id] or (not md.is_supported(b) and not (known and known[b.id]))
	end

	local plan = { deletes = {}, groups = {}, inserted = 0, warnings = {}, rewrite = false, protected = 0 }
	local anchor, cur = nil, nil
	for _, op in ipairs(ops) do
		local retained = op.kind == "match" or (op.kind == "delete" and protected(op.remote))
		if op.kind == "delete" and retained and not local_keeps[op.remote.id] and not edge[op.remote.id] then
			plan.protected = plan.protected + 1
		end
		if retained then
			if plan.groups[1] and plan.groups[1].after == nil then
				-- Content must go before the first retained block, which the API can't do.
				plan.rewrite = true
			end
			anchor, cur = op.remote.id, nil
		elseif op.kind == "delete" then
			plan.deletes[#plan.deletes + 1] = op.remote.id
		else
			local b = op.block
			if b._keep then
				if not remote_ids[b._keep] then
					plan.warnings[#plan.warnings + 1] = "block " .. b._keep .. " no longer exists in Notion; skipped"
				end
			else
				if not cur then
					cur = { after = anchor, blocks = {} }
					plan.groups[#plan.groups + 1] = cur
				end
				cur.blocks[#cur.blocks + 1] = b
				plan.inserted = plan.inserted + 1
			end
		end
	end

	if plan.rewrite then
		plan.deletes, plan.inserted = {}, 0
		local kept = false
		for _, b in ipairs(remote) do
			if protected(b) then
				kept = true
			else
				plan.deletes[#plan.deletes + 1] = b.id
			end
		end
		local all = {}
		for _, b in ipairs(locals) do
			if not b._keep then
				all[#all + 1] = b
			end
		end
		plan.groups = { { after = nil, blocks = all } }
		plan.inserted = #all
		if kept then
			plan.warnings[#plan.warnings + 1] =
				"content added above preserved Notion blocks; they were moved to the top"
		end
	end
	return plan
end

return M
