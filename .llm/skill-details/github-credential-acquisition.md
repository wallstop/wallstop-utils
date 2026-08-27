# GitHub Credential Acquisition (Expanded)

Supports the lightweight skill stub in `.llm/skills/github-credential-acquisition`.

## Ladder (check silently, prompt at most once per host)

Agents must resolve a usable GitHub API credential by stepping down this list. Each step is
silent unless noted; stop at the first success and never print or log the secret value.

1. **Environment tokens**: prefer `$env:GH_TOKEN`, then `$env:GITHUB_TOKEN`. Validate cheaply
   (`GET https://api.github.com/user`) when it matters; a present-but-invalid env token is
   treated like absent once a validation call returns 401.
2. **Agent cache**: `/home/vscode/.cache/wallstop-agent/github-credential.json` (mode 0600,
   JSON `{protocol,host,username,password}`). Read with a JSON parser, never `cat` into a
   shared terminal. Validate against `/user` and reuse while the response is 200.
3. **VSCode connector**: the configured `credential.helper` routes through
   `/tmp/vscode-remote-containers-*/…git-credential-helper`. Probe with
   `printf 'protocol=https\nhost=github.com\n\n' | timeout 45 git credential fill` and parse
   the `password=` line. Two operational hazards:
   - The helper **blocks indefinitely** when no live VSCode client session is connected to
     answer the fill request; always wrap in an OS-level timeout and treat timeout as
     "connector unavailable", not "no credential".
   - The helper can answer instantly at one point in a session and hang later if the client
     disconnects; re-probe after operator activity before declaring it dead.
4. **Prompt exactly once, then cache both places** so no future session asks again:
   - Write/refresh the JSON cache file from step 2 (`chmod 600`, parent dir `chmod 700`).
   - Feed `protocol/host/username/password` lines plus a blank line into
     `git credential approve` so credential-tooling consumers see it too.
   - Scope expectations: classic `repo, workflow`; fine-grained equivalent is
     Contents + Pull requests + Actions (read) scoped to `wallstop/wallstop-utils`.

## Hygiene rules

- Never echo the password, commit it, or embed it in logs/artifacts/test data. Extract with
  `grep '^password=' … | cut -d= -f2-` straight into an ephemeral shell variable inside the
  same command line that uses it, and delete temporary fill-output files immediately after use.
- Prefer `curl --max-time` on every API call so a stalled endpoint cannot wedge a session.
- Rate limits: authenticated calls cost little; do not bulk-poll CI faster than ~60s intervals.
- When the API is unreachable but SSH works (branch push), finish local work first; PR
  creation/comments can wait until any ladder step succeeds again.

## Why this exists

Session 2026-08-26 (PR #78) discovered the full shape: connector answered instantly early,
then hung mid-session (no responsive desktop client), forcing a one-time operator paste.
Caching file + `git credential approve` makes every later step silent; the documented ladder
keeps that behavior reproducible instead of tribal.
