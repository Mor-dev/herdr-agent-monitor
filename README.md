# herdr Agent Monitor (`herdrAgentMonitor`)

A [DankMaterialShell](https://danklinux.com) bar widget that monitors live agent and workspace status from [herdr](https://herdr.dev) (local and remote SSH machines) and optionally the **Herdr Desktop App** (`hc` / `herdr-core`).

![herdr Agent Monitor popout](assets/screenshot.png)

## Features

- **Single-Machine & Multi-Machine Ready**: Works out of the box with a single local `herdr` instance (hiding machine filters when only `local` is present), and automatically discovers enabled SSH machines from `herdr machine list` (`herdr --machine <host> api snapshot`) when configured.
- **Workspace & Agent Tree**: Groups agents by workspace/space with context token usage (`⛁ 68% (325k)`), rate-limit status (`5h 100%`), stripped terminal title, and live state (`blocked`, `working`, `idle`, `done`).
- **Herdr Desktop App (`hc`) Toggle**: Optional setting and one-click `hc` chip in the popout header to include `hc ls --json` terminals from `herdr-core`.
- **One-Click Focus**: Click an agent card to focus its pane (`herdr [--machine <host>] agent focus <pane_id>` or `herdr-app do agent.focus --terminal <addr>`) or click a workspace header to focus that space. On Niri, also focuses the `herdr` terminal window (or middle-click the bar pill).
- **IPC Commands**:
  ```bash
  dms ipc call herdrAgentMonitor toggle
  dms ipc call herdrAgentMonitor open
  dms ipc call herdrAgentMonitor close
  dms ipc call herdrAgentMonitor refresh
  dms ipc call herdrAgentMonitor status
  ```

## Dependencies

- Required: `herdr`, `python3`, `jq`
- Optional: `hc` and `herdr-app` (Herdr Desktop App), `niri` (compositor window focus)

## Install

```bash
git clone https://github.com/Mor-dev/herdr-agent-monitor ~/.config/DankMaterialShell/plugins/HerdrAgentMonitor
dms ipc call plugin-scan scan
dms ipc call plugins enable herdrAgentMonitor
```

## License

MIT
