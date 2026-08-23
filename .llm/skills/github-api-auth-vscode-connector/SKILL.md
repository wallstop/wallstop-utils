---
name: github-api-auth-vscode-connector
description: Obtain and use GitHub API credentials inside this devcontainer via the VSCode git askpass connector chain, with check-first, single-prompt-and-cache etiquette.
metadata:
  category: GitHub
  keywords: github api auth, vscode askpass, credential helper, bearer token, gh cli fallback, github mcp server, pull request creation, single prompt, cache credentials
  details: ../../skill-details/github-api-auth-vscode-connector.md
---

# GitHub API Auth Via VSCode Connector

Follow the expanded repository guide:
[GitHub API Auth Via VSCode Connector](../../skill-details/github-api-auth-vscode-connector.md).

Channel priority for GitHub operations: VSCode connector/extension first, then git, then gh
(install https://github.com/github/github-mcp-server as an MCP server only if those fail).
