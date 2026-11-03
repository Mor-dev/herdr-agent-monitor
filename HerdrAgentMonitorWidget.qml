import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Services
import qs.Modules.Plugins
import "." as Local

PluginComponent {
    id: root
    property var popoutService: null

    readonly property bool includeRemoteMachines: pluginData.includeRemoteMachines ?? true
    readonly property bool includeHerdrCore: pluginData.includeHerdrCore ?? false
    readonly property bool includeEmptySpaces: pluginData.includeEmptySpaces ?? false
    readonly property string pillDisplayMode: pluginData.pillDisplayMode || "breakdown"
    readonly property int baseIntervalMs: Math.max(10, (pluginData.refreshInterval || 15)) * 1000
    readonly property int maxIntervalMs: 120000
    readonly property int maxBackoffSteps: 3

    readonly property string pluginDir: PluginService.getPluginPath("herdrAgentMonitor")
    readonly property string collectorScript: pluginDir + "/collect-fleet"
    readonly property string focusScript: pluginDir + "/focus-target"

    PluginGlobalVar {
        id: sharedFleet
        varName: "fleetData"
        defaultValue: ({
            ok: false,
            totals: { machines_total: 0, machines_reachable: 0, workspaces: 0, agents: 0, blocked: 0, working: 0, idle: 0, done: 0 },
            machines: [],
            agents: []
        })
    }
    PluginGlobalVar {
        id: sharedFailures
        varName: "consecutiveFailures"
        defaultValue: 0
    }
    PluginGlobalVar {
        id: sharedLastPoll
        varName: "lastPollMs"
        defaultValue: 0
    }
    PluginGlobalVar {
        id: sharedSelectedMachine
        varName: "selectedMachine"
        defaultValue: "all"
    }
    PluginGlobalVar {
        id: sharedRefreshing
        varName: "isRefreshing"
        defaultValue: false
    }

    readonly property var fleet: sharedFleet.value || ({ totals: {}, machines: [], agents: [] })
    readonly property var totals: fleet.totals || ({ machines_total: 0, machines_reachable: 0, workspaces: 0, agents: 0, blocked: 0, working: 0, idle: 0, done: 0 })
    readonly property var machines: fleet.machines || []
    readonly property var agents: fleet.agents || []
    readonly property string selectedMachine: sharedSelectedMachine.value || "all"
    readonly property int currentIntervalMs: Math.min(baseIntervalMs * Math.pow(2, sharedFailures.value), maxIntervalMs)

    property var fleetPopout: null
    property bool fleetOpenRequested: false
    property real fleetOpenRequestedAt: 0
    property bool lastPollIncludedRemote: false

    Component.onCompleted: Local.HerdrFleetController.registerRoot(root)
    Component.onDestruction: Local.HerdrFleetController.unregisterRoot(root)

    pillRightClickAction: () => root.refreshNow()

    onIncludeRemoteMachinesChanged: root.refreshNow()
    onIncludeHerdrCoreChanged: root.refreshNow()
    onIncludeEmptySpacesChanged: root.refreshNow()

    function toggleHcQuick() {
        var nextVal = !root.includeHerdrCore;
        if (typeof PluginService !== "undefined" && PluginService.savePluginData) {
            PluginService.savePluginData("herdrAgentMonitor", "includeHerdrCore", nextVal);
        }
        Qt.callLater(root.refreshNow);
    }

    function statusColor(st) {
        switch (st) {
        case "blocked": return Theme.error;
        case "working": return Theme.primary;
        case "idle": return Theme.warning;
        case "done": return Theme.success;
        default: return Theme.surfaceText;
        }
    }

    function statusIcon(st) {
        switch (st) {
        case "blocked": return "warning";
        case "working": return "bolt";
        case "idle": return "pause_circle";
        case "done": return "check_circle";
        default: return "help";
        }
    }

    function statusLabel(st) {
        switch (st) {
        case "blocked": return I18n.trFor("herdrAgentMonitor", "blocked");
        case "working": return I18n.trFor("herdrAgentMonitor", "working");
        case "idle": return I18n.trFor("herdrAgentMonitor", "idle");
        case "done": return I18n.trFor("herdrAgentMonitor", "done");
        default: return I18n.trFor("herdrAgentMonitor", "unknown");
        }
    }

    function machineIcon(m) {
        if (!m) return "dns";
        if (m.backend === "hc") return "desktop_windows";
        if (m.isLocal) return "computer";
        return "dns";
    }

    readonly property color barIconColor: {
        if ((totals.agents || 0) === 0)
            return Theme.widgetIconColor;
        if ((totals.blocked || 0) > 0)
            return Theme.error;
        if ((totals.working || 0) > 0)
            return Theme.primary;
        return Theme.primary;
    }

    readonly property string pillLabelText: {
        var total = totals.agents || 0;
        var blocked = totals.blocked || 0;
        var working = totals.working || 0;
        if (pillDisplayMode === "iconOnly" || total === 0)
            return "";
        if (pillDisplayMode === "activeOnly") {
            var active = blocked + working;
            return active > 0 ? active.toString() : "";
        }
        if (pillDisplayMode === "breakdown") {
            var parts = [];
            if (blocked > 0) parts.push(blocked + "!");
            if (working > 0) parts.push(working + "⚡");
            parts.push(total.toString());
            return parts.join("·");
        }
        return total.toString();
    }

    readonly property var visibleMachines: {
        var list = root.machines || [];
        if (root.selectedMachine === "all")
            return list;
        var filtered = [];
        for (var i = 0; i < list.length; i++) {
            if (list[i].id === root.selectedMachine)
                filtered.push(list[i]);
        }
        return filtered.length > 0 ? filtered : list;
    }

    function mergeCachedRemoteMachines(freshPayload) {
        if (!freshPayload || root.lastPollIncludedRemote || !root.includeRemoteMachines)
            return freshPayload;
        var prevMachines = (sharedFleet.value && sharedFleet.value.machines) || [];
        var remoteCached = [];
        for (var i = 0; i < prevMachines.length; i++) {
            var pm = prevMachines[i];
            if (pm && !pm.isLocal && pm.backend === "herdr")
                remoteCached.push(pm);
        }
        if (remoteCached.length === 0)
            return freshPayload;

        var localList = (freshPayload.machines || []).slice();
        var mergedMachines = [];
        var insertedRemote = false;
        for (var j = 0; j < localList.length; j++) {
            if (localList[j].backend === "hc" && !insertedRemote) {
                mergedMachines = mergedMachines.concat(remoteCached);
                insertedRemote = true;
            }
            mergedMachines.push(localList[j]);
        }
        if (!insertedRemote)
            mergedMachines = mergedMachines.concat(remoteCached);

        var totals = {
            machines_total: mergedMachines.length,
            machines_reachable: 0,
            workspaces: 0,
            agents: 0,
            blocked: 0,
            working: 0,
            idle: 0,
            done: 0
        };
        var flatAgents = [];
        for (var k = 0; k < mergedMachines.length; k++) {
            var m = mergedMachines[k];
            if (m.reachable)
                totals.machines_reachable += 1;
            var wsList = m.workspaces || [];
            totals.workspaces += wsList.length;
            var c = m.counts || {};
            totals.agents += c.total || 0;
            totals.blocked += c.blocked || 0;
            totals.working += c.working || 0;
            totals.idle += c.idle || 0;
            totals.done += c.done || 0;
            for (var w = 0; w < wsList.length; w++) {
                var agList = wsList[w].agents || [];
                for (var a = 0; a < agList.length; a++)
                    flatAgents.push(agList[a]);
            }
        }
        return {
            ok: totals.machines_reachable > 0,
            totals: totals,
            machines: mergedMachines,
            agents: flatAgents
        };
    }

    Process {
        id: collectorProc
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                sharedRefreshing.set(false);
                var raw = (text || "").trim();
                if (!raw) {
                    sharedFailures.set(Math.min(sharedFailures.value + 1, root.maxBackoffSteps));
                    return;
                }
                try {
                    var parsed = JSON.parse(raw);
                    sharedFleet.set(root.mergeCachedRemoteMachines(parsed));
                    sharedFailures.set(0);
                } catch (e) {
                    sharedFailures.set(Math.min(sharedFailures.value + 1, root.maxBackoffSteps));
                }
            }
        }

        onExited: code => {
            sharedRefreshing.set(false);
            if (code !== 0) {
                sharedFailures.set(Math.min(sharedFailures.value + 1, root.maxBackoffSteps));
            }
        }
    }

    // Remote SSH snapshots are queried only while the popout is open or on explicit manual refresh,
    // avoiding periodic background SSH fanout while keeping the local bar pill live.
    function runCollector(pollRemote) {
        if (!root.pluginId || collectorProc.running || !root.pluginDir)
            return;
        var queryRemote = (pollRemote === undefined ? root.isPopoutOpen() : pollRemote) && root.includeRemoteMachines;
        root.lastPollIncludedRemote = queryRemote;
        sharedRefreshing.set(true);
        collectorProc.command = [
            "python3",
            root.collectorScript,
            "--include-hc", root.includeHerdrCore ? "1" : "0",
            "--include-remote", queryRemote ? "1" : "0",
            "--include-empty-spaces", root.includeEmptySpaces ? "1" : "0"
        ];
        collectorProc.running = true;
    }

    function maybeRefresh() {
        if (!root.pluginId)
            return;
        var now = Date.now();
        if (now - sharedLastPoll.value < root.currentIntervalMs - 500)
            return;
        sharedLastPoll.set(now);
        root.runCollector(root.isPopoutOpen());
    }

    function refreshNow() {
        if (!root.pluginId)
            return;
        sharedLastPoll.set(Date.now());
        root.runCollector(true);
    }

    function focusAgent(agent) {
        if (!agent || !root.pluginDir)
            return;
        Quickshell.execDetached([
            "bash",
            root.focusScript,
            "agent",
            agent.backend || "herdr",
            agent.machine_id || "local",
            agent.pane_id || ""
        ]);
    }

    function focusWorkspace(machine, ws) {
        if (!machine || !ws || !root.pluginDir)
            return;
        Quickshell.execDetached([
            "bash",
            root.focusScript,
            "workspace",
            machine.backend || "herdr",
            machine.id || "local",
            ws.workspace_id || ""
        ]);
    }

    function focusHerdrWindow() {
        if (!root.pluginDir)
            return;
        Quickshell.execDetached(["bash", root.focusScript, "window"]);
    }

    // IPC handlers
    function isPopoutOpen() {
        if (fleetOpenRequested && Date.now() - fleetOpenRequestedAt >= 1500)
            fleetOpenRequested = false;
        return fleetOpenRequested || !!fleetPopout?.shouldBeVisible;
    }

    function openFromIpc() {
        if (isPopoutOpen())
            return "HERDR_ALREADY_OPEN";
        fleetOpenRequested = true;
        fleetOpenRequestedAt = Date.now();
        triggerPopout();
        return "HERDR_OPENING";
    }

    function closeFromIpc() {
        if (!isPopoutOpen())
            return "HERDR_ALREADY_CLOSED";
        fleetOpenRequested = false;
        closePopout();
        return "HERDR_CLOSED";
    }

    function toggleFromIpc() {
        return isPopoutOpen() ? closeFromIpc() : openFromIpc();
    }

    function refreshFromIpc() {
        refreshNow();
        return "HERDR_REFRESH_QUEUED";
    }

    function statusFromIpc() {
        return JSON.stringify(root.totals);
    }

    Timer {
        interval: root.currentIntervalMs
        running: !!root.pluginId
        repeat: true
        triggeredOnStart: true
        onTriggered: root.maybeRefresh()
    }

    popoutWidth: Theme.smallBreakpoint
    popoutHeight: Theme.dialogMaxWidth

    horizontalBarPill: Component {
        Item {
            implicitWidth: hRow.implicitWidth
            implicitHeight: hRow.implicitHeight

            Row {
                id: hRow
                spacing: Theme.spacingS

                DankIcon {
                    name: "hub"
                    color: root.barIconColor
                    size: Theme.barIconSize(root.barThickness, -Theme.spacingXS)
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.pillLabelText
                    color: (root.totals.blocked || 0) > 0 ? Theme.error : Theme.surfaceText
                    font.pixelSize: Theme.barTextSize(root.barThickness)
                    font.weight: (root.totals.blocked || 0) > 0 ? Font.Bold : Font.Normal
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.pillLabelText.length > 0
                }
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -Theme.spacingXS
                acceptedButtons: Qt.MiddleButton
                onClicked: mouse => {
                    if (mouse.button === Qt.MiddleButton)
                        root.focusHerdrWindow();
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: vCol.implicitWidth
            implicitHeight: vCol.implicitHeight

            Column {
                id: vCol
                spacing: Theme.spacingXS

                DankIcon {
                    name: "hub"
                    color: root.barIconColor
                    size: Theme.barIconSize(root.barThickness, -Theme.spacingXS)
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: (root.totals.agents || 0).toString()
                    color: (root.totals.blocked || 0) > 0 ? Theme.error : Theme.surfaceText
                    font.pixelSize: Theme.barTextSize(root.barThickness)
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.pillDisplayMode !== "iconOnly" && (root.totals.agents || 0) > 0
                }
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -Theme.spacingXS
                acceptedButtons: Qt.MiddleButton
                onClicked: mouse => {
                    if (mouse.button === Qt.MiddleButton)
                        root.focusHerdrWindow();
                }
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: I18n.trFor("herdrAgentMonitor", "herdr Agent Monitor")
            detailsText: I18n.trFor("herdrAgentMonitor", "%1 agents · %2 spaces · %3/%4 hosts").arg(root.totals.agents || 0).arg(root.totals.workspaces || 0).arg(root.totals.machines_reachable || 0).arg(root.totals.machines_total || 0)

            onParentPopoutChanged: {
                if (parentPopout)
                    root.fleetPopout = parentPopout;
            }
            Component.onCompleted: {
                if (parentPopout)
                    root.fleetPopout = parentPopout;
                root.refreshNow();
            }
            Connections {
                target: popout.parentPopout
                function onOpened() {
                    root.fleetOpenRequested = false;
                    root.refreshNow();
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // ── Top status bar + quick actions (hc toggle & refresh) ──
                Row {
                    width: parent.width
                    spacing: Theme.spacingXS

                    // Summary status badges
                    StyledRect {
                        height: summaryRow.implicitHeight + Theme.spacingXS * 2
                        width: summaryRow.implicitWidth + Theme.spacingM * 2
                        radius: Theme.cornerRadiusFull
                        color: Theme.surfaceContainer

                        Row {
                            id: summaryRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            Row {
                                spacing: Theme.spacingXXS
                                visible: (root.totals.blocked || 0) > 0
                                DankIcon {
                                    name: "warning"
                                    color: Theme.error
                                    size: Theme.iconSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: I18n.trFor("herdrAgentMonitor", "%1 blocked").arg(root.totals.blocked || 0)
                                    color: Theme.error
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Row {
                                spacing: Theme.spacingXXS
                                DankIcon {
                                    name: "bolt"
                                    color: Theme.primary
                                    size: Theme.iconSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: I18n.trFor("herdrAgentMonitor", "%1 working").arg(root.totals.working || 0)
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Row {
                                spacing: Theme.spacingXXS
                                DankIcon {
                                    name: "pause_circle"
                                    color: Theme.warning
                                    size: Theme.iconSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: I18n.trFor("herdrAgentMonitor", "%1 idle").arg(root.totals.idle || 0)
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Row {
                                spacing: Theme.spacingXXS
                                visible: (root.totals.done || 0) > 0
                                DankIcon {
                                    name: "check_circle"
                                    color: Theme.success
                                    size: Theme.iconSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: I18n.trFor("herdrAgentMonitor", "%1 done").arg(root.totals.done || 0)
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    Item {
                        width: Math.max(Theme.spacingXS, parent.width - summaryRow.parent.width - hcChip.width - refreshBtn.width - Theme.spacingXS * 3)
                        height: 1
                    }

                    // Quick toggle for Herdr Desktop App (hc)
                    StyledRect {
                        id: hcChip
                        height: hcRow.implicitHeight + Theme.spacingXS * 2
                        width: hcRow.implicitWidth + Theme.spacingS * 2
                        radius: Theme.cornerRadiusFull
                        color: root.includeHerdrCore ? Theme.withAlpha(Theme.primary, 0.22) : Theme.surfaceContainer
                        border.width: root.includeHerdrCore ? Theme.outlineWidth : 0
                        border.color: root.includeHerdrCore ? Theme.withAlpha(Theme.primary, 0.55) : "transparent"

                        Row {
                            id: hcRow
                            anchors.centerIn: parent
                            spacing: Theme.spacingXS

                            DankIcon {
                                name: "desktop_windows"
                                size: Theme.iconSizeSmall
                                color: root.includeHerdrCore ? Theme.primary : Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                text: "hc"
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: root.includeHerdrCore ? Font.Medium : Font.Normal
                                color: root.includeHerdrCore ? Theme.primary : Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleHcQuick()
                        }
                    }

                    // Refresh button
                    StyledRect {
                        id: refreshBtn
                        width: hcChip.height
                        height: hcChip.height
                        radius: Theme.cornerRadiusFull
                        color: refreshMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer

                        DankIcon {
                            anchors.centerIn: parent
                            name: sharedRefreshing.value ? "sync" : "refresh"
                            size: Theme.iconSizeSmall
                            color: sharedRefreshing.value ? Theme.primary : Theme.surfaceText
                        }

                        MouseArea {
                            id: refreshMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.refreshNow()
                        }
                    }
                }

                // ── Machine Filter Chips (shown when multiple machines/backends exist) ──
                DFlickable {
                    visible: root.machines.length > 1
                    width: parent.width
                    height: chipsRow.implicitHeight + Theme.spacingXXS * 2
                    contentWidth: chipsRow.implicitWidth
                    contentHeight: height
                    flickableDirection: Flickable.HorizontalFlick
                    showScrollBar: false
                    fadeEdges: false
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Row {
                        id: chipsRow
                        spacing: Theme.spacingXS
                        height: parent.height

                        // "All" chip
                        StyledRect {
                            height: allChipText.implicitHeight + Theme.spacingXS * 2
                            width: allChipText.implicitWidth + Theme.spacingM * 2
                            radius: Theme.cornerRadiusFull
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.selectedMachine === "all" ? Theme.primary : Theme.surfaceContainer

                            StyledText {
                                id: allChipText
                                anchors.centerIn: parent
                                text: I18n.trFor("herdrAgentMonitor", "All (%1)").arg(root.totals.agents || 0)
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: root.selectedMachine === "all" ? Font.Medium : Font.Normal
                                color: root.selectedMachine === "all" ? Theme.onPrimary : Theme.surfaceText
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: sharedSelectedMachine.set("all")
                            }
                        }

                        Repeater {
                            model: root.machines

                            delegate: StyledRect {
                                readonly property bool isSelected: root.selectedMachine === modelData.id
                                readonly property int mBlocked: (modelData.counts && modelData.counts.blocked) || 0
                                readonly property int mWorking: (modelData.counts && modelData.counts.working) || 0
                                readonly property int mTotal: (modelData.counts && modelData.counts.total) || 0

                                height: mChipRow.implicitHeight + Theme.spacingXS * 2
                                width: mChipRow.implicitWidth + Theme.spacingM * 2
                                radius: Theme.cornerRadiusFull
                                anchors.verticalCenter: parent.verticalCenter
                                color: isSelected ? Theme.primary : Theme.surfaceContainer
                                opacity: modelData.reachable ? 1.0 : 0.55

                                Row {
                                    id: mChipRow
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingXS

                                    Rectangle {
                                        width: Theme.spacingS
                                        height: Theme.spacingS
                                        radius: Theme.cornerRadiusFull
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !modelData.reachable || mBlocked > 0 || mWorking > 0
                                        color: !modelData.reachable ? Theme.outline : (mBlocked > 0 ? Theme.error : Theme.primary)
                                    }

                                    StyledText {
                                        text: (modelData.short_label || modelData.id) + " (" + mTotal + ")"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: isSelected ? Font.Medium : Font.Normal
                                        color: isSelected ? Theme.onPrimary : Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: sharedSelectedMachine.set(isSelected ? "all" : modelData.id)
                                }
                            }
                        }
                    }
                }

                // ── Main Scrollable Tree: Machine -> Space -> Agents ──
                DFlickable {
                    id: fleetFlick
                    width: parent.width
                    height: Math.min(Theme.menuMaxHeight, Math.max(Theme.listItemHeight * 3, treeColumn.implicitHeight))
                    contentWidth: width
                    contentHeight: treeColumn.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: treeColumn
                        width: parent.width
                        spacing: Theme.spacingM

                        StyledText {
                            visible: (root.totals.agents || 0) === 0 && !sharedRefreshing.value
                            text: I18n.trFor("herdrAgentMonitor", "No active agents across monitored machines")
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        Repeater {
                            model: root.visibleMachines

                            delegate: Column {
                                id: machineBlock
                                required property var modelData
                                width: treeColumn.width
                                spacing: Theme.spacingXS
                                visible: (modelData.workspaces && modelData.workspaces.length > 0) || !modelData.reachable

                                // Machine Header (shown when multiple machines exist or when local is unreachable)
                                StyledRect {
                                    visible: root.machines.length > 1 || !machineBlock.modelData.reachable
                                    width: parent.width
                                    height: machineHeaderRow.implicitHeight + Theme.spacingS
                                    radius: Theme.cornerRadius
                                    color: Theme.withAlpha(Theme.primary, 0.10)

                                    Row {
                                        id: machineHeaderRow
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.margins: Theme.spacingS
                                        spacing: Theme.spacingXS

                                        DankIcon {
                                            name: root.machineIcon(machineBlock.modelData)
                                            size: Theme.iconSizeSmall
                                            color: machineBlock.modelData.reachable ? Theme.primary : Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: machineBlock.modelData.label || machineBlock.modelData.id
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Bold
                                            color: Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: machineBlock.modelData.reachable
                                                ? I18n.trFor("herdrAgentMonitor", "· %1 spaces · %2 agents").arg((machineBlock.modelData.workspaces || []).length).arg((machineBlock.modelData.counts && machineBlock.modelData.counts.total) || 0)
                                                : I18n.trFor("herdrAgentMonitor", "· offline")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: machineBlock.modelData.reachable ? Theme.surfaceVariantText : Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                // Workspaces inside this Machine
                                Repeater {
                                    model: machineBlock.modelData.workspaces || []

                                    delegate: Column {
                                        id: wsBlock
                                        required property var modelData
                                        width: machineBlock.width
                                        spacing: Theme.spacingXS

                                        // Space (Workspace) Subheader (clickable to focus space)
                                        StyledRect {
                                            width: parent.width
                                            height: wsHeaderRow.implicitHeight + Theme.spacingXS * 2
                                            radius: Theme.cornerRadiusSmall
                                            color: wsMouse.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                                            Row {
                                                id: wsHeaderRow
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                anchors.leftMargin: Theme.spacingS
                                                anchors.rightMargin: Theme.spacingS
                                                spacing: Theme.spacingXS

                                                DankIcon {
                                                    id: wsFolderIcon
                                                    name: wsBlock.modelData.focused ? "folder_open" : "folder"
                                                    size: Theme.iconSizeSmall
                                                    color: wsBlock.modelData.focused ? Theme.primary : Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }

                                                StyledText {
                                                    width: parent.width - wsFolderIcon.width - wsPaneCountText.implicitWidth - wsHeaderRow.spacing * 2
                                                    elide: Text.ElideRight
                                                    text: "[" + (wsBlock.modelData.number || "?") + "] " + (wsBlock.modelData.label || wsBlock.modelData.workspace_id)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.Medium
                                                    color: wsBlock.modelData.focused ? Theme.primary : Theme.surfaceVariantText
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }

                                                StyledText {
                                                    id: wsPaneCountText
                                                    text: (wsBlock.modelData.pane_count || 0) === 1 ? I18n.trFor("herdrAgentMonitor", "1 pane") : I18n.trFor("herdrAgentMonitor", "%1 panes").arg(wsBlock.modelData.pane_count || 0)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                    opacity: 0.75
                                                    anchors.verticalCenter: parent.verticalCenter
                                                }
                                            }

                                            MouseArea {
                                                id: wsMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root.focusWorkspace(machineBlock.modelData, wsBlock.modelData);
                                                    popout.closePopout();
                                                }
                                            }
                                        }

                                        // Agents inside this Space
                                        Repeater {
                                            model: wsBlock.modelData.agents || []

                                            delegate: StyledRect {
                                                id: agentCard
                                                required property var modelData
                                                width: wsBlock.width
                                                height: agentCol.implicitHeight + Theme.spacingS * 2
                                                radius: Theme.cornerRadius
                                                color: agentMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer
                                                border.width: modelData.agent_status === "blocked" ? Theme.outlineWidth : 0
                                                border.color: modelData.agent_status === "blocked" ? Theme.error : "transparent"

                                                Row {
                                                    id: agentRow
                                                    anchors.left: parent.left
                                                    anchors.right: parent.right
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    anchors.margins: Theme.spacingS
                                                    spacing: Theme.spacingS

                                                    DankIcon {
                                                        id: statusIconItem
                                                        name: root.statusIcon(agentCard.modelData.agent_status)
                                                        color: root.statusColor(agentCard.modelData.agent_status)
                                                        size: Theme.iconSizeSmall
                                                        anchors.verticalCenter: parent.verticalCenter
                                                    }

                                                    Column {
                                                        id: agentCol
                                                        width: agentRow.width - statusIconItem.width - agentRow.spacing
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        spacing: Theme.spacingXXS

                                                        Row {
                                                            width: parent.width
                                                            spacing: Theme.spacingXS

                                                            StyledRect {
                                                                id: agentBadge
                                                                height: badgeText.implicitHeight + Theme.spacingXXS * 2
                                                                width: badgeText.implicitWidth + Theme.spacingS
                                                                radius: Theme.cornerRadiusXS
                                                                color: Theme.withAlpha(root.statusColor(agentCard.modelData.agent_status), 0.18)
                                                                anchors.verticalCenter: parent.verticalCenter

                                                                StyledText {
                                                                    id: badgeText
                                                                    anchors.centerIn: parent
                                                                    text: (agentCard.modelData.agent || I18n.trFor("herdrAgentMonitor", "agent")) + " · " + (agentCard.modelData.pane_id || "")
                                                                    font.pixelSize: Theme.fontSizeSmall
                                                                    font.weight: Font.Medium
                                                                    color: root.statusColor(agentCard.modelData.agent_status)
                                                                }
                                                            }

                                                            StyledText {
                                                                width: parent.width - agentBadge.width - Theme.spacingS
                                                                elide: Text.ElideRight
                                                                text: agentCard.modelData.title || agentCard.modelData.agent
                                                                color: Theme.surfaceText
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                font.weight: Font.Medium
                                                                anchors.verticalCenter: parent.verticalCenter
                                                            }
                                                        }

                                                        StyledText {
                                                            width: parent.width
                                                            elide: Text.ElideMiddle
                                                            text: {
                                                                var parts = [];
                                                                if (agentCard.modelData.subtitle)
                                                                    parts.push(agentCard.modelData.subtitle);
                                                                if (agentCard.modelData.cwd)
                                                                    parts.push(agentCard.modelData.cwd);
                                                                if (agentCard.modelData.context)
                                                                    parts.push(agentCard.modelData.context);
                                                                if (agentCard.modelData.limit)
                                                                    parts.push(agentCard.modelData.limit);
                                                                parts.push(root.statusLabel(agentCard.modelData.agent_status));
                                                                return parts.join("  ·  ");
                                                            }
                                                            color: Theme.surfaceVariantText
                                                            font.pixelSize: Theme.fontSizeSmall
                                                        }
                                                    }
                                                }

                                                MouseArea {
                                                    id: agentMouse
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        root.focusAgent(agentCard.modelData);
                                                        popout.closePopout();
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
