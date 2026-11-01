# herdr Agent Monitor

A [DankMaterialShell](https://danklinux.com) bar widget that shows live agent status from
[herdr](https://herdr.dev), the agent-aware terminal multiplexer for Claude Code and similar
coding agents, and from the Herdr desktop app (`herdr-app`).

## What it does

- Bar pill: a count of active agents. The icon is neutral with no agents, primary once any
  exist, and error when one is blocked waiting on you.
- Popout: every agent's title, working directory, and status, sorted most-urgent-first.
- Click an agent to focus it (`herdr agent focus <pane_id>`, or
  `herdr-app do agent.focus --terminal <address>` for Herdr app agents).

Calls the `herdr` and `hc` (herdr-core, which runs the Herdr app's terminals) CLIs directly, with
no other dependency, no bundled scripts, and nothing to configure. Works with either one running,
or both; agents from both are listed together.

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
