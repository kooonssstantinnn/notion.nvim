# Contributing

Thanks for helping! Bug reports, fixes and small focused PRs are all welcome.

## Development

Requirements: Neovim 0.10+, `curl`, and [StyLua](https://github.com/JohnnyMorganz/StyLua).

```sh
nvim --headless -u NONE -l tests/run.lua   # run the tests
stylua .                                   # format
```

The tests mock the Notion API and use a temporary login file, so they never
touch your real workspace or tokens.

To try your checkout in Neovim (lazy.nvim):

```lua
{ dir = "~/path/to/notion.nvim", opts = {} }
```

## Guidelines

- Add a test in `tests/run.lua` for bug fixes and new markdown mappings.
- A change to the markdown format must round-trip: Notion → markdown → Notion
  must not change unedited blocks (that is what keeps comments alive).
- Never log or print tokens, and never write them inside the project folder.
- Update `README.md`, `doc/notion.txt` and `CHANGELOG.md` for user-visible changes.

## Code layout

| File | Purpose |
|---|---|
| `lua/notion/api.lua` | Notion REST client (curl) |
| `lua/notion/markdown.lua` | Notion blocks ⇄ markdown |
| `lua/notion/diff.lua` | Block-level publish plan |
| `lua/notion/sync.lua` | sync / pull / publish flows |
| `lua/notion/store.lua` | local files, index and base snapshots |
| `lua/notion/ui.lua`, `modal.lua` | dashboard and centered prompts |
| `lua/notion/config.lua` | options and per-folder logins |
