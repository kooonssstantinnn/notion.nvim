# notion.nvim

[![CI](https://github.com/kooonssstantinnn/notion.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/kooonssstantinnn/notion.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<!-- TODO: add a screenshot / GIF of the dashboard: ![dashboard](https://…) -->

Edit your Notion pages as markdown in Neovim. Sync pages down, write freely
(`:w` saves **locally only**), and push to Notion only when you run `:Notion publish`.

- No dependencies besides `curl` (Neovim 0.10+)
- Publishes only the blocks you changed, so comments and block links on
  untouched parts of the page survive
- Detects when someone edited the page in Notion since your last sync and
  lets you diff before overwriting
- Child pages, databases, uploaded files and other blocks markdown can't
  represent are kept as `<!-- notion:keep … -->` placeholders and left alone
- Per-folder logins: each project can use its own integration/workspace
- A lazygit-style dashboard with page tree, unpublished list and diff preview

> **Status: beta.** It works on real workspaces, but keep backups of important
> pages and please [report issues](https://github.com/kooonssstantinnn/notion.nvim/issues).
> This is an unofficial plugin, not affiliated with Notion Labs, Inc.

## Setup

**1. Create an integration** at <https://www.notion.so/profile/integrations> →
*New integration* → copy the **Internal Integration Secret**.

**2. Share pages with it**: open a page in Notion → `⋯` → *Connections* → add
your integration. Sub-pages are included automatically.

**3. Install** (lazy.nvim):

```lua
{
  "kooonssstantinnn/notion.nvim",
  cmd = "Notion",
  opts = {},
  keys = {
    { "<leader>nn", "<cmd>Notion<cr>", desc = "Notion: dashboard" },
    { "<leader>no", "<cmd>Notion open<cr>", desc = "Notion: open page" },
    { "<leader>ns", "<cmd>Notion sync<cr>", desc = "Notion: sync" },
    { "<leader>np", "<cmd>Notion publish<cr>", desc = "Notion: publish buffer" },
    { "<leader>nd", "<cmd>Notion diff<cr>", desc = "Notion: diff with Notion" },
    { "<leader>nN", "<cmd>Notion new<cr>", desc = "Notion: new page" },
  },
}
```

**4. Log in and sync**:

```vim
:Notion login     " paste the secret; saved for THIS folder only (stdpath('state'), 0600)
:Notion sync      " downloads every page shared with the integration into ./notion
:Notion           " open the dashboard
```

Logins are **per folder**: each project can be connected to a different
integration or workspace, and a folder you haven't logged into asks you to log in
(`L` in the dashboard). Tokens are kept in `stdpath('state')/notion/auth.json`,
never inside the project. `:Notion logout` removes the current folder's login.

Token precedence: the `token` option in `setup()` > the folder's login > `$NOTION_TOKEN`. Run `:checkhealth notion` if anything goes wrong.

Full documentation: `:help notion`.

## Dashboard

`:Notion` opens a lazygit-style dashboard:

```
╭ [1] Status ─────────────────╮╭ [0] Unpublished changes · Onboarding ──────╮
│ ● Acme · notion.nvim        ││--- Notion (last sync)                      │
│ 4 pages · 2 unpublished     ││+++ local                                   │
│ synced 5m ago · ~/p/notion  ││ - laptop                                   │
╰─────────────────────────────╯│-- accounts                                 │
╭ [2] Working ────────────────╮│+- accounts **today**                       │
│  ▾ Engineering              ││+- meet the team                            │
│M     Onboarding             ││                                            │
╰─────────────────────────────╯│                                            │
╭ [3] Pages ──────────────────╮│                                            │
│  ▸ Engineering ★            ││                                            │
│A   Ideas                    ││                                            │
╰─────────────────────────────╯│                                            │
╭ [4] Unpublished (2) ────────╮│                                            │
│A   Ideas                    ││                                            │
│M   Onboarding               ││                                            │
╰─────────────────────────────╯╰────────────────────────────────────────────╯
 Open: ⏎ | Publish: p | Sync: s | Pull: P | Diff: d | New: n | Browser: o | …
```

- **[1] Status** shows the folder's login (`● workspace · integration`, or
  `○ Not logged in · press L`), page counts, last sync time and the folder.
- **[2] Working** holds the pages you're working on (`w` adds or removes one), with
  their sub-pages. It's saved per folder, and the dashboard opens here, so you don't
  have to dig through hundreds of pages. Pages you `get` and new drafts are added automatically.
- **[3] Pages** shows your Notion page tree. `M` means unpublished changes, `A` means a new
  draft and `★` means it's in Working. Press `/` to search titles and content as you type;
  the list shows the matches, the preview jumps to the first one and `⏎` opens the page there.
- **[4] Unpublished** lists everything waiting to be published.
- **[0] Preview** shows the page. If the page has local edits, it shows a diff against the last synced version instead. The diff is computed locally, with no API call.

Press `S` to choose the folder's sync mode in a modal: **all pages** shared with the
integration, or **only pages you already have** (pulled pages get updated, and new
sub-pages created under them in Notion come along; unrelated new pages are skipped, add
them with `g`). The choice is saved per folder and shown in the Status panel
(`sync: all` / `sync: pulled only`); the `sync_all` option is the default until you pick.

Keys: `⏎`/`e` open, `/` search, `g` get a page from Notion, `w` add to / remove from Working, `p` publish, `s` sync, `S` sync mode, `P` pull, `d` diff with the live Notion page
(shown in the right panel; `Esc` returns to the preview or clears the search), `D` full-screen side-by-side diff, `n` new draft,
`o` browser, `L` log in this folder, `r` refresh, `␣`/`za`/`h`/`l` fold, `1 2 3 4 0` / `⇥` switch panels,
`?` help, `q` close.

Choices and prompts (publish confirmation, parent page, conflicts, new page title)
open as a small modal in the center: `j`/`k` or numbers to pick, `⏎` to confirm, `Esc` to cancel.

Pages are plain `.md` files in a `notion/` folder at the **project root** (the
git root of Neovim's cwd, or the cwd itself). Each project has its own folder and
index, and you can browse it with any file explorer, fuzzy finder or grep. The
folder is created on the first `:Notion sync` / `:Notion new`.

```
your-project/
└── notion/
    ├── Engineering.md
    ├── Onboarding.md
    ├── .notion-index.json   # page IDs, sync state (paths stored relative)
    └── .notion/base/        # last-synced copies used for diffs
```

To keep it out of git, add `/notion/` to `.gitignore`. To use a single global
folder instead, set `sync_dir = "~/notion"`.

## Commands

| Command | What it does |
|---|---|
| `:Notion` / `:Notion ui` | Toggle the dashboard |
| `:Notion open` | Pick a synced page with `vim.ui.select` (`●` = unpublished changes) |
| `:Notion sync` | Pull pages changed in Notion (including pages whose sub-pages were added or renamed). Pages with unpublished local edits are **skipped**, never overwritten. Pages deleted, archived or unshared in Notion are removed locally (each one is double-checked with Notion first; files with unpublished edits are kept, and you're asked before removing most of the folder) |
| `:Notion get[!] [url\|id\|title]` | Pull just one page: by URL/ID, or search Notion by title and pick. Asks whether to include its sub-pages (`!` includes them). Adds it to Working |
| `:Notion search [text]` | Quickfix list of matching lines across pulled pages (every word must appear; lowercase ignores case) |
| `:Notion work` | Add the current page to Working, or remove it |
| `:w` | Save locally. Nothing is sent to Notion |
| `:Notion publish` | Push the current buffer to Notion (asks for confirmation, shows blocks added / removed and title changes). If the page changed in Notion since your last sync you can overwrite, see the diff, or cancel |
| `:Notion diff` | Side-by-side diff: Notion (left) vs your local copy (right) |
| `:Notion status` | Quickfix list of every doc with unpublished changes |
| `:Notion pull[!]` | Re-download the current page (`!` skips the "discard changes?" prompt) |
| `:Notion new [title]` | New local draft. It's created in Notion on first publish (you pick a parent page) |
| `:Notion browse` | Open the page in your browser |
| `:Notion login` / `logout` | Save / remove the token for the current folder (verified with Notion before saving) |

Any markdown file can be published, not only files in `sync_dir`. Without a
`notion_id` in its frontmatter, `:Notion publish` creates a new page and adds the ID to the file.

Each file starts with frontmatter that links it to its page:

```markdown
---
notion_id: 1a2b3c4d-....
title: Project plan
url: https://www.notion.so/...
---

# Goals
```

Edit `title:` to rename the page on the next publish. For a new draft, set
`parent:` to a page URL/ID to choose where it gets created.

## Configuration

Defaults:

```lua
require("notion").setup({
  token = nil,              -- string or function; overrides the folder login
  token_env = "NOTION_TOKEN", -- fallback when the folder has no login
  sync_dir = <project root>/notion, -- string, or function returning a path
  default_parent = nil,     -- page URL/ID new pages go under (asked when nil)
  confirm_publish = true,
  notify_on_save = true,    -- one-time "saved locally" hint per buffer
  sync_on_startup = false,
  sync_all = true,          -- default sync mode; false = only pages you already pulled. `S` in the dashboard overrides it per folder
  filter = nil,             -- fun(page): boolean, choose which pages to sync
})
```

Example: read the token from 1Password:

```lua
token = function()
  return vim.fn.system({ "op", "read", "op://Private/Notion/credential" })
end,
```

Statusline component: `require("notion").statusline()` returns `Notion ✓`
(published), `Notion ●` (unpublished changes), `Notion ＋` (new draft), or `""`.

`User` autocmds you can hook into:

| Event | When | `data` |
|---|---|---|
| `NotionSynced` | after `:Notion sync` | — |
| `NotionPulled` | after a page is re-downloaded | `{ id, buf }` |
| `NotionPublished` | after a successful publish | `{ id, buf }` |
| `NotionLogin` | after login / logout | — |
| `NotionWorking` | after `:Notion work` | `{ doc, working }` |

## Markdown mapping

| Notion | Markdown |
|---|---|
| Headings 1–3 | `#`, `##`, `###` (`####+` becomes heading 3) |
| Bold / italic / strike / code / underline | `**b**` `*i*` `~~s~~` `` `c` `` `<u>u</u>` |
| Links, page mentions | `[text](url)` (mentions become links once that block is edited) |
| Bulleted / numbered / to-do lists | `-`, `1.`, `- [ ]` / `- [x]`, nested by indentation |
| Toggle | `▸ Title` with indented children |
| Quote / callout | `> text` / `> [!NOTE] 💡` + `> text` |
| Code | fenced blocks with language (```` ```mermaid ```` works; Notion can show it as a diagram) |
| Equation | `$$ … $$` block, `$x$` inline |
| Table | pipe table (first row is the header) |
| Divider | `---` |
| External image | `![caption](url)` |
| Empty block (blank line in Notion) | an extra blank line: one blank line separates blocks, each additional one is an empty block |
| Anything else | `<!-- notion:keep <id> <type> -->` (kept as-is in Notion) |

Keep placeholders: leave the line in place to keep the block. Deleting the line removes that
block from Notion on publish. Blocks (e.g. sub-pages) added in Notion after your last
sync are never removed, even if they aren't in your file.

Links: Notion only accepts full URLs. On publish, `www.…` becomes `https://www.…`, a page
ID becomes its Notion URL, and a relative link to another synced `.md` file becomes that
page's URL. Any other link (e.g. `#anchor`, `https://…` placeholders) is published as plain
text, with a warning. Images must be `http(s)` URLs; local image paths are published as text.

See [`examples/feature-test.md`](examples/feature-test.md) for a page that uses every
supported feature, including Mermaid diagrams.

Notion text colors and background colors are not represented. Blocks you
don't edit keep their colors. Blocks you edit are recreated without them.

## Limits

- Notion's API can't insert blocks before the first block of a page. If you add
  content **above everything else**, publish rewrites the whole page. This loses
  comments on that page.
- Changes are diffed per top-level block. Editing one item of a nested list
  recreates that top-level item with all its children.
- Database properties other than the title are not synced.
- Login is with an integration token. OAuth isn't supported.
- Notion reports `last_edited_time` to the minute. Two edits in the same minute
  (one in Notion, one published from Neovim) may not be flagged as a conflict.

## Security and privacy

- The plugin only talks to `https://api.notion.com`, using `curl`.
- The token is passed to `curl` on stdin, so it doesn't show up in `ps`.
- Logins are saved in `stdpath('state')/notion/auth.json` with mode `0600`,
  outside your projects, so they can't be committed.
- Your pages are stored as plain files in `notion/`. Add it to `.gitignore` if
  the project is shared.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run the tests with:

```sh
nvim --headless -u NONE -l tests/run.lua
```

## License

[MIT](LICENSE)
