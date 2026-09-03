import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    property var popoutService: null

    // Fully self-contained -- calls the `herdr` CLI directly (no rofi_plus/personal-
    // script dependency), so this is safe to publish/install standalone. Scoped to
    // this machine's single local herdr session (whichever `herdr agent list --json`
    // targets with no --session/HERDR_SOCKET_PATH given) -- not multi-session-aware
    // like rofi_plus's own herdrSessions widget, since env-var injection isn't exposed
    // through Proc.qml's runCommand() wrapper. Good enough for the common case (one
    // herdr instance running); extend later if multi-session turns out to matter.
    property var agents: []

    // Proc is a pragma Singleton shared across every bar/screen instance, and its
    // debounce registry is keyed by the id passed to runCommand -- a fixed string
    // would let two instances (e.g. one per monitor) silently clobber each other's
    // callback (confirmed as a real bug elsewhere in this project's other herdr
    // widget -- see rofi_plus's CLAUDE.md). Random per-instance id sidesteps it.
    readonly property string instanceId: Math.random().toString(36).slice(2)

    // Ordering is a judgment call, not something herdr's docs define: "blocked"
    // (waiting on you -- e.g. a permission prompt) and "idle" (finished, no next
    // instruction yet) both plausibly need attention sooner than "working" (busy,
    // nothing to do yet), so they sort first. Adjust if it doesn't match how these
    // states actually feel in practice.
    function statusPriority(st) {
        switch (st) {
        case "blocked": return 0;
        case "idle": return 1;
        case "unknown": return 2;
        case "working": return 3;
        case "done": return 4;
        default: return 5;
        }
    }

    function statusColor(st) {
        switch (st) {
        case "blocked": return Theme.error;
        case "idle": return Theme.warning;
        case "working": return Theme.primary;
        case "done": return Theme.success;
        default: return Theme.surfaceText;
        }
    }

    function statusIcon(st) {
        switch (st) {
        case "blocked": return "warning";
        case "idle": return "pause_circle";
        case "working": return "bolt";
        case "done": return "check_circle";
        default: return "help";
        }
    }

    function shortCwd(cwd) {
        const home = Quickshell.env("HOME") || "";
        return (home && cwd && cwd.indexOf(home) === 0) ? "~" + cwd.slice(home.length) : (cwd || "");
    }

    readonly property var sortedAgents: {
        const list = root.agents.slice();
        list.sort((a, b) => statusPriority(a.agent_status) - statusPriority(b.agent_status));
        return list;
    }

    readonly property color worstStateColor: {
        if (root.agents.length === 0)
            return Theme.surfaceText;
        let best = root.agents[0];
        for (const a of root.agents) {
            if (statusPriority(a.agent_status) < statusPriority(best.agent_status))
                best = a;
        }
        return statusColor(best.agent_status);
    }

    function refresh() {
        // `herdr agent list` has no --json flag of its own (its help text lists no options at
        // all, unlike `session list`) -- JSON is its unconditional default output. Passing --json
        // anyway worked inconsistently in testing (succeeded once, then failed with a usage error
        // on an identical later call, cause not pinned down) -- dropping the flag entirely is the
        // resilient fix regardless of why, since the bare command reliably returns the same JSON.
        Proc.runCommand("herdrAgentMonitor.refresh." + root.instanceId, ["herdr", "agent", "list"], (stdout, exitCode) => {
            if (exitCode !== 0) {
                root.agents = [];
                return;
            }
            try {
                const data = JSON.parse(stdout);
                root.agents = (data.result && data.result.agents) || [];
            } catch (e) {
                root.agents = [];
            }
        });
    }

    function focusAgent(paneId) {
        Quickshell.execDetached(["herdr", "agent", "focus", paneId]);
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    popoutWidth: 340
    popoutHeight: 320

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "smart_toy"
                color: root.worstStateColor
                size: Theme.barIconSize(root.barThickness, -4)
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.agents.length.toString()
                color: Theme.surfaceText
                font.pixelSize: Theme.barTextSize(root.barThickness)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.agents.length > 0
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                name: "smart_toy"
                color: root.worstStateColor
                size: Theme.barIconSize(root.barThickness, -4)
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.agents.length.toString()
                color: Theme.surfaceText
                font.pixelSize: Theme.barTextSize(root.barThickness)
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.agents.length > 0
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "herdr Agents"
            detailsText: root.agents.length + " active"
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    visible: root.agents.length === 0
                    text: "No active agents"
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                }

                Repeater {
                    model: root.sortedAgents

                    delegate: StyledRect {
                        width: parent.width
                        height: row.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: rowMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer

                        Row {
                            id: row
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            DankIcon {
                                name: root.statusIcon(modelData.agent_status)
                                color: root.statusColor(modelData.agent_status)
                                size: Theme.iconSizeSmall
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                StyledText {
                                    text: modelData.terminal_title_stripped || modelData.agent
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                }

                                StyledText {
                                    text: root.shortCwd(modelData.cwd) + "  ·  " + modelData.agent_status
                                    color: Theme.surfaceText
                                    opacity: 0.7
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                root.focusAgent(modelData.pane_id);
                                popout.closePopout();
                            }
                        }
                    }
                }
            }
        }
    }
}
