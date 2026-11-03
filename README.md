# herdr Agent Monitor (`herdrAgentMonitor`)

A [DankMaterialShell](https://danklinux.com) bar widget that monitors live agent and workspace status from [herdr](https://herdr.dev) (local and remote SSH machines) and optionally the **Herdr Desktop App** (`hc` / `herdr-core`).

![herdr Agent Monitor popout](assets/screenshot.png)

## Features

- **Single-Machine & Multi-Machine Ready**: Works out of the box with a single local `herdr` instance (hiding machine filters and headers when only `local` is present), and automatically discovers enabled SSH machines from `herdr machine list` (`herdr --machine <host> api snapshot`) and `hc` machines when configured.
- **Workspace & Agent Tree**: Groups agents by workspace/space with context token usage (`⛁ 68% (325k)`), rate-limit status (`5h 100%`), stripped terminal title, and live state (`blocked`, `working`, `idle`, `done`).
- **Herdr Desktop App (`hc`) Multi-Machine & Space Support**: Built-in setting and one-click `hc` chip in the popout header to monitor `herdr-core` / `herdr-app` across local and remote `hc` machines (`herdr-app ls`, `~/.local/state/herdr-core/default`, `hc get <addr> --json`, and `hc ls --json`).
- **Multi-Row Machine Filter Chips**: Wrapping multi-row filter pills (`All`, `herdr` machines, and `hc · <host>` machines) with live counts and status indicator dots.
- **One-Click Focus**: Click an agent card to focus its pane (`herdr [--machine <host>] agent focus <pane_id>` or `herdr-app do agent.focus --terminal <addr>`) or click a workspace header to focus that space (`herdr [--machine <host>] workspace focus <ws_id>` or `herdr-app do space.select --id <space_id>`). On Niri, also focuses the `herdr` / `herdr-app` window (or middle-click the bar pill).
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
