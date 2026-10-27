local M = {}

function M.check()
	local health = vim.health
	local config = require("notion.config")
	local api = require("notion.api")

	health.start("notion.nvim")

	if vim.fn.has("nvim-0.10") == 1 then
		health.ok("Neovim " .. tostring(vim.version()))
	else
		health.error("Neovim 0.10+ is required")
	end

	if vim.fn.executable("curl") == 1 then
		health.ok("curl found")
	else
		health.error("curl is not installed")
		return
	end

	local dir = config.sync_dir()
	if vim.fn.isdirectory(dir) == 1 and vim.fn.filewritable(dir) == 2 then
		health.ok("sync_dir: " .. dir)
	else
		health.warn("sync_dir does not exist yet: " .. dir, "It is created on the first :Notion sync or :Notion new")
	end

	local token = config.token()
	if not token then
		health.error("Not logged in for " .. dir, {
			"Create an internal integration at https://www.notion.so/profile/integrations",
			"Then run :Notion login in this folder (logins are per folder)",
		})
		return
	end
	local auth = config.folder_auth()
	health.ok(
		auth and ("Logged in for this folder (" .. (auth.workspace or auth.name or "?") .. ")")
			or "Using a token from setup() or $" .. config.options.token_env
	)

	local cmd, stdin, _ = api._curl_args("GET", "/users/me", nil, token)
	local res = vim.system(cmd, { stdin = stdin, text = true }):wait(15000)
	local status, data = api._parse(res.stdout)
	if res.code == 0 and status == 200 then
		health.ok(("Connected as “%s”"):format(data and data.name or "?"))
		health.info("Remember to share pages with the integration: page ⋯ menu → Connections → your integration")
	else
		health.error(("API check failed (%s): %s"):format(status, data and data.message or vim.trim(res.stderr or "")))
	end
end

return M
