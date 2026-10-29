# Security Policy

## Supported versions

notion.nvim is in beta. Only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via GitHub:
[Report a vulnerability](https://github.com/kooonssstantinnn/notion.nvim/security/advisories/new)

Please include:

- a description of the issue and its impact
- steps to reproduce (Neovim version, OS, config if relevant)
- any suggested fix

You can expect an initial response within 7 days. Once a fix is released,
the advisory will be published and you'll be credited unless you prefer otherwise.

## Scope

Things especially relevant to this plugin:

- leaking the Notion integration token (logs, error messages, files outside
  `stdpath('state')`, wrong file permissions)
- the token being sent anywhere other than `api.notion.com`
- shell/command injection through `curl` arguments, page titles or file paths
- writing files outside the configured sync directory (path traversal via page titles)

Out of scope: issues in Notion's API itself. Report those to Notion.
