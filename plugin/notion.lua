if vim.g.loaded_notion then
	return
end
vim.g.loaded_notion = true

local subcommands = { "ui", "open", "sync", "publish", "pull", "diff", "status", "new", "browse", "login", "logout" }

vim.api.nvim_create_user_command("Notion", function(opts)
	require("notion").command(opts)
end, {
	nargs = "*",
	bang = true,
	desc = "Notion: ui | open | sync | publish | pull[!] | diff | status | new [title] | browse | login | logout",
	complete = function(arglead, cmdline)
		if cmdline:match("^%S+%s+%S+%s") then
			return {}
		end
		return vim.tbl_filter(function(s)
			return vim.startswith(s, arglead)
		end, subcommands)
	end,
})
