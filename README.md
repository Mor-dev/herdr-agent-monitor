# herdr Agent Monitor (`herdrAgentMonitor`)

A [DankMaterialShell](https://danklinux.com) bar widget that monitors live agent and workspace status from [herdr](https://herdr.dev) (local and remote SSH machines) and optionally the **Herdr Desktop App** (`hc` / `herdr-core`).

![herdr Agent Monitor popout](assets/screenshot.png)

## Features

- **Single-Machine & Multi-Machine Ready**: Works out of the box with a single local `herdr` instance (hiding machine filters and headers when only `local` is present), and automatically discovers enabled SSH machines from `herdr machine list` (`herdr --machine <host> api snapshot`) and `hc` machines when configured.
- **Workspace & Agent Tree**: Groups all active agents across `herdr` CLI and `Herdr App` (`hc` spaces) by workspace/space with context token usage (`⛁ 68% (325k)`), rate-limit status (`5h 100%`), stripped terminal title / task label (without auxiliary split-shell clutter or cross-pane tab title bleed), and live state (`blocked`, `working`, `idle`, `done`).
- **Interactive Status Filter Pills & Live Search**: Click the top `blocked`, `working`, `idle`, or `done` summary pills to filter the fleet by status (click again to reset), and use the live multi-token search bar to filter across agent names, titles, pane IDs, workspaces, machines, and working directories (`Enter` focuses the first match).
- **Herdr Desktop App (`hc`) Multi-Machine & Space Support**: Built-in setting and one-click `hc` chip in the popout header to monitor `herdr-core` / `herdr-app` across local and remote `hc` machines (`herdr-app ls`, `~/.local/state/herdr-core/default`, `hc get <addr> --json`, and `hc ls --json`).
- **Multi-Row Machine Filter Chips**: Wrapping multi-row filter pills (`All`, `herdr` machines, and `hc · <host>` machines) with live counts and status indicator dots.
- **One-Click Focus & Cross-Machine TUI Switching**: Click any agent card or workspace header to focus the corresponding `herdr` TUI terminal or `herdr-app` window in Niri, check `~/.local/state/herdr/client/endpoint-selection.json` to switch the active `herdr` TUI client endpoint (`Alt+w`) only when jumping between machines (without sending `ESC` into the active PTY), and focus the exact workspace/space, tab, and pane (`pane.focus` RPC / `herdr agent focus` / `herdr-app do pane.focus`).
- **Clickable Herdr Notifications**: Intercepts `Herdr` notifications in DankMaterialShell (`NotificationService`) and re-emits them with a default click action that resolves and focuses the originating machine, workspace, tab, and pane.
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
