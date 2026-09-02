# GitHub API Auth Via VSCode Connector (Expanded)

This expanded guide supports the lightweight skill stub in `.llm/skills/github-api-auth-vscode-connector/SKILL.md`.

## Etiquette (user directive, binding)

- **Check first**: probe cached/ambient credentials (existing store files, `GH_TOKEN`/`GITHUB_TOKEN`,
  anonymous public-API reads) before any credential acquisition.
- **Prompt and cache**: if unauthenticated, acquire credentials at most ONCE, then cache them for the
  session (mode-600 file outside the repository).
- **Never repeatedly prompt**: repeated failed acquisition attempts surface as interactive prompts in
  the user's VSCode window. Two bounded failures on a channel means fall through to the next channel,
  not retry.

## Channel Priority

1. VSCode connector/extension (git askpass chain).
2. git over SSH (push/pull; no API mutations).
3. gh CLI — NOT installed in this devcontainer image.
4. Fallback: install https://github.com/github/mcp-server as an opencode MCP server.

`gh` absence is not a blocker: once a token exists, `curl` with an `Authorization: Bearer <token>`
header performs every API mutation (PR create/update, issue comment, check polling).

## The Working Recipe (VSCode Connector)

VSCode injects `GIT_ASKPASS`, `VSCODE_GIT_ASKPASS_NODE`, `VSCODE_GIT_ASKPASS_MAIN`,
`VSCODE_GIT_IPC_HANDLE`. The askpass answers git's HTTPS prompts from the user's GitHub session.

Do NOT invoke `askpass-main.js` directly: without `VSCODE_GIT_ASKPASS_PIPE` and
`VSCODE_GIT_ASKPASS_TYPE=https` it exits with "Missing or invalid credentials. / Missing pipe", which
is an invocation error, not proof that auth is missing. `git credential fill` against this helper also
hangs when the UI does not answer that channel; treat empty output as fall-through, never as a retry
signal.

Sanctioned capture-and-cache: let git drive ONE real HTTPS operation with an isolated store helper so
the askpass-supplied token lands in a session-local file:

```bash
rm -f /tmp/opencode/git-cred-store && touch /tmp/opencode/git-cred-store && chmod 600 /tmp/opencode/git-cred-store
GIT_TERMINAL_PROMPT=0 timeout 60 \
  git -c credential.helper= \
      -c "credential.helper=store --file=/tmp/opencode/git-cred-store" \
      push --dry-run https://github.com/<owner>/<repo>.git HEAD:refs/heads/<probe-ref>
# --dry-run mutates nothing; the auth challenge still completes and gets stored.
```

Then extract and validate WITHOUT echoing secrets:

```bash
TOKEN=$(sed -E 's#^https://[^:]+:([^@]+)@github.com$#\1#' /tmp/opencode/git-cred-store)
curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" https://api.github.com/user
```

Rules:

- Store files live under `/tmp/opencode/` (never inside the repository), mode 600, deleted when done.
- Never print tokens, embed them in command output, logs, commit messages, or `.llm/` files.
- Validate with `GET /user` before any mutating call.
- Anonymous GETs on public repositories (issues, PRs, checks) need no token; use them for read-only
  triage so no prompt ever occurs for pure inspection.

## Pull Requests Without gh

```bash
jq -Rs '{title: $t, head: $h, base: "main", body: .}' body.md > payload.json   # with --arg t/--arg h
POST /repos/{owner}/{repo}/pulls  -> 201 returns number + html_url
```

Poll PR checks anonymously or authenticated via `/repos/{owner}/{repo}/commits/<sha>/check-runs`;
address failures before handoff (GOAL.md green-state requirement).

## Diagnostics Quick Reference

| Symptom | Meaning | Action |
| --- | --- | --- |
| "Missing pipe" from askpass-main.js | Direct invocation missing env contract | Use the git-driven recipe above |
| `git credential fill` hangs/empty | UI did not answer that channel | Fall through channel order once |
| HTTP 401 Bad credentials | Cached token stale/revoked | Re-acquire ONCE via recipe, re-cache |
