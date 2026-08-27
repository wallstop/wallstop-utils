# agent-notify

Portable hook-based push notifications for terminal AI coding agents. When any
of your agentic sessions finishes a turn, errors out, or blocks waiting on you,
your Android phone gets an ntfy push with enough detail to decide whether you
need to come back.

```
claude/codex/copilot/opencode/nanocoder
        │  hook payload (JSON on stdin)
        ▼
~/.local/bin/agent-notify          normalize -> state machine -> cooldown dedup
        │  POST https://ntfy.sh/<secret-topic>
        ▼
ntfy.sh ──► Android app (FCM instant or UnifiedPush/WebSocket)
        │
        └─ every event also appended to ~/.local/state/agent-notify/log.jsonl
           (the raw data used later for noise/tuning analysis)
```

States and priorities:

| State     | Meaning                          | Priority | Emoji tag         |
|-----------|----------------------------------|----------|-------------------|
| `waiting` | needs your input/approval        | high     | 🔔 bell            |
| `blocked` | failed (API error, rate limit…)  | max      | 🚨 rotating_light  |
| `done`    | turn finished                    | default  | ✅ heavy_check_mark|
| `ended`   | session closed                   | low      | 😴 zzz             |

Unknown/noisy events are dropped before they ever reach your phone (but still
logged), so adding a new hook source can never spam you by accident.

## Requirements

- bash >= 4 (macOS ships 3.x — install via Homebrew if needed)
- jq, curl (git optional: adds branch names to messages)

## Quickstart (once, per account)

1. Generate a private topic. The topic name *is* the credential:

       TOPIC="agent-alerts-$(openssl rand -hex 12)"

2. Install the **ntfy Android app**, add server `https://ntfy.sh`, subscribe to
   `$TOPIC`. Play Store build = instant FCM delivery; F-Droid build = battery
   exemption recommended, works fully Google-free (UnifiedPush-compatible).
3. Copy `bin/*` somewhere on PATH and make them executable:

       mkdir -p ~/.local/bin
       cp agent-notify/bin/agent-notify ~/.local/bin/
       chmod +x ~/.local/bin/agent-notify

4. Create `~/.config/agent-notify/agent-notify.env` (chmod 600). The core
   sources this file automatically on every invocation, so hooks inherit config
   without any shell-profile wiring. Entries in the file win over ambient
   environment, which makes one synced file authoritative per machine:

       export AGENT_NOTIFY_TOPIC="<$TOPIC from step 1>"
       export AGENT_NOTIFY_MACHINE_LABEL=work-laptop   # short, stable, yours

5. Smoke test end-to-end:

       echo '{"hook_event_name":"Stop","cwd":"'"$PWD"'"}' \
         | ~/.local/bin/agent-notify claude

   Your phone should buzz within seconds: `[work-laptop] Claude: DONE`.

## Wiring the harnesses

Drop-in configs live in `adapters/`. User-level installs survive tool updates;
project-level copies get committed to repos instead.

| Harness    | File                                          | Install to                                  |
|------------|-----------------------------------------------|---------------------------------------------|
| Claude Code| `adapters/claude/settings-hooks.json`         | merge `hooks` block into `~/.claude/settings.json` |
| Codex CLI  | `adapters/codex/hooks.json`                   | `~/.codex/hooks.json`, then `/hooks` trust review once |
| Copilot CLI| `adapters/copilot/agent-notify.json`          | `~/.copilot/hooks/agent-notify.json`        |
| opencode   | `adapters/opencode/agent-notify.js`           | `~/.config/opencode/plugins/agent-notify.js` |
| nanocoder  | `adapters/nanocoder/notify-send`              | `cp … ~/.local/bin/notify-send` and ensure `~/.local/bin` precedes `/usr/bin` in PATH |

Notes per harness:

- **Claude Code** — hooks fire `Notification` (all flavors: permission/idle
  prompts, elicitation dialogs…), `Stop`, `StopFailure`, `SessionEnd`.
- **Codex CLI** — hooks must be trusted once via the interactive `/hooks`
  browser. `PermissionRequest` arrives async so approvals are never delayed.
- **Copilot CLI** — config uses PascalCase event keys on purpose: those payloads
  carry `hook_event_name` so agent-notify identifies events unambiguously.
  Hook stdout stays empty, which Copilot interprets as no decision — safe.
- **opencode** — pure event subscription; logs through the same core script.
- **nanocoder** — enable its built-in desktop notifications in `/settings`;
  the shim converts those into pushes and, when a real `notify-send` exists
  (desktop Linux/macOS tools), still execs it after forwarding.

## Configuration reference

| Variable                    | Default                | Purpose                        |
|-----------------------------|------------------------|--------------------------------|
| `AGENT_NOTIFY_URL`          | `https://ntfy.sh`      | broker base URL (self-hosting) |
| `AGENT_NOTIFY_TOPIC`        | *(none)*               | target topic; unset ⇒ send is skipped but logged |
| `AGENT_NOTIFY_TOKEN`        | *(none)*               | sent as `Authorization: Bearer …` (self-hosted ACLs) |
| `AGENT_NOTIFY_MACHINE_LABEL`| codespace id / hostname| appears in every title & tags; Codespaces default keeps only the first `-`-segment — override when running parallel clones |
| `AGENT_NOTIFY_COOLDOWN_SECS`| `90`                   | same (machine,harness,state) resend window; armed **only** after a confirmed 2xx publish (a failed network attempt never eats your next alert); `0` disables |
| `AGENT_NOTIFY_SNIPPET_MAX`  | `160`                  | detail truncation length       |
| `AGENT_NOTIFY_DEBUG`        | off                    | `1` prints stderr diagnostics  |

## Tests

`tests/run.sh` is data-driven: every file in `tests/fixtures/*.json` embeds its
own `x_expect` block (state, priority, title/body regexes, tag presence,
truncation, skip) and the runner asserts all fixtures plus lifecycle behaviors:
cooldown arming/suppression/release, missing-topic skip, malformed payloads
never crash or send, stdout purity during send mode, failing-curl containment,
env-file bootstrap, bearer-token header presence, and shim long-option
parsing. A stub curl captures headers/body, so nothing leaves the machine:

    ./tests/run.sh          # prints PASS / FAIL totals

To cover a new event type you have not seen yet: capture the real hook payload,
drop it in `fixtures/` with an `x_expect`, rerun. No test code changes needed.

## Operating it day to day

Everything is observable in one JSONL file (~5 MB auto-rotation keeps `.1`):

    LOG=~/.local/state/agent-notify/log.jsonl

    tail -f "$LOG" | jq .

    # counts by result today
    jq -r --arg d "$(date +%F)" 'select(.ts|startswith($d)) | .result' "$LOG" | sort | uniq -c

    # weekly volume by harness x state — feed this back into cooldown tuning
    jq -r 'select(.ts >= "2026-08-17" and .ts < "2026-08-24") | "\(.harness) \(.state)"' "$LOG" | sort | uniq -c

    # anything failing?
    jq 'select(.result | startswith("failed"))' "$LOG"

Expect `deduped` entries while a session hammers the same state; they are the
mechanism keeping your pocket quiet, evidence they work lives here too.

## Privacy & security posture

- Topic name is the sole credential — keep it long/random, rotate by resubscribing.
- Message bodies contain repo/project names and up to 160 chars of the agent's
  last message; they transit (and rest briefly at) ntfy.sh. If that ever feels
  too exposed, drop `AGENT_NOTIFY_SNIPPET_MAX` to `0` (detail suppressed to an
  ellipsis; project/branch still shown) or move to your own broker — the client
  code does not change either way.
- Receive-only by design: no inbound endpoints exist except the ntfy TLS API.
  Approving tool calls from the phone is intentionally NOT wired.
- State dir (`~/.local/state/agent-notify`) is created chmod 700.

## Upgrading to self-hosted (when volume justifies ~$3.50/mo)

ntfy is a single static binary. Run it on a Lightsail/EC2 nano behind Caddy +
Let's Encrypt, set `auth-default-access: deny-all`, mint yourself an access
token (`ntfy user add --role user … && ntfy token add you`), then point the
client at it by changing two values in `agent-notify.env`:

    export AGENT_NOTIFY_URL=https://ntfy.yourdomain.tld
    export AGENT_NOTIFY_TOKEN=tk_xxxxxxxxxxxxxxxx

Topic stays whatever name you created under that broker. Client code, adapter
configs, and phone subscription are untouched apart from adding the server.

Official guide: https://docs.ntfy.sh/config/

## Troubleshooting

- **No push at all?** Check `log.jsonl` first: `no-topic` means config didn't
  reach the hook; `failed curl_rc=… http=403` means auth/token trouble;
  an absent line means the harness never fired its hook.
- **Codex specifically**: SessionEnd runs under a hard 3 s budget on their side;
  agent-notify compensates (no git lookups, ≤4 s network cap) but a *network
  hang* during session end can still lose just that last "ended" ping while all
  waiting/blocked/done events arrive normally.
- **Duplicate pushes?** Raise `AGENT_NOTIFY_COOLDOWN_SECS`. Silent drops where
  you expected a page? Look for `deduped:true` lines — that's the window doing
  its job; shrink it instead of disabling outright.
- **nanocoder shim**: short options (`-u/-t/-i/-a`) and the common long forms
  (`--urgency`, `--icon`, `--app-name`, `--expire-time`, both space and `=`
  value styles) are parsed away before forwarding; positional summary/body map
  onto the desktop classifier.

## Uninstall

Remove the hooks block from each harness config, delete copied binaries
(`~/.local/bin/agent-notify`, `~/.local/bin/notify-send`), drop the opencode
plugin file, remove `~/.config/agent-notify/`, and optionally delete
`~/.local/state/agent-notify`.

## License

MIT. Fixture texts and scripts contain no personal data; keep real payloads out
of commits.
