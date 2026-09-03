# herdr Agent Monitor

A [DankMaterialShell](https://danklinux.com) bar widget that shows live agent status from
[herdr](https://herdr.dev) — the agent-aware terminal multiplexer for Claude Code and similar
coding agents.

## What it does

- Bar pill: a count of active herdr agents, with an icon colored by the most urgent status
  present (blocked → error, idle → warning, working → primary, done → success).
- Popout: every agent's title, working directory, and status, sorted most-urgent-first.
- Click an agent to focus its pane (`herdr agent focus <pane_id>`).

Calls the `herdr` CLI directly — no other dependency, no bundled scripts, nothing to configure.
Requires `herdr` installed and its server running (`herdr` with no session flags starts one).

Scoped to this machine's single local herdr session — not multi-session-aware, since injecting a
per-call `HERDR_SOCKET_PATH` isn't exposed through Quickshell's `Proc.qml` wrapper. Fine for the
common case of one herdr instance running.

## Install

```
git clone https://github.com/Mor-dev/herdr-agent-monitor ~/.config/DankMaterialShell/plugins/HerdrAgentMonitor
dms ipc plugin-scan scan
dms ipc call plugins enable herdrAgentMonitor
```

Then add it to a bar (Settings → Bar → widgets, or edit `settings.json`'s `barConfigs[].rightWidgets`
directly) and restart `dms.service` if it doesn't appear live.

## License

MIT
