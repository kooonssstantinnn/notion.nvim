# Changelog

All notable changes are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-27

First public release (beta).

### Added

- Sync pages shared with an integration into `notion/` at the project root as markdown.
- `:w` saves locally; `:Notion publish` pushes only the changed blocks.
- Conflict detection when a page changed in Notion since the last sync.
- Lazygit-style dashboard with page tree, unpublished list and diff preview.
- Centered modal for prompts and choices.
- Per-folder logins stored outside the project (`stdpath('state')`, mode 0600).
- Markdown mapping for headings, lists, to-dos, toggles, quotes, callouts, code
  (including Mermaid), equations, tables, dividers, external images and empty blocks.
- Unsupported blocks kept as `<!-- notion:keep -->` placeholders.
- Link fixing on publish (relative `.md` links, page IDs, `www.` links).
- `User` autocmds: `NotionSynced`, `NotionPulled`, `NotionPublished`, `NotionLogin`.
- `:checkhealth notion`.

[Unreleased]: https://github.com/kooonssstantinnn/notion.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kooonssstantinnn/notion.nvim/releases/tag/v0.1.0
