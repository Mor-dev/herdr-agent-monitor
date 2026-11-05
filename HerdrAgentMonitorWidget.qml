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
    readonly property bool includeHerdrCore: pluginData.includeHerdrCore ?? true
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
    PluginGlobalVar {
        id: sharedSearchQuery
        varName: "searchQuery"
        defaultValue: ""
    }
    PluginGlobalVar {
        id: sharedSelectedStatus
        varName: "selectedStatus"
        defaultValue: "all"
    }
    PluginGlobalVar {
        id: sharedInterceptedNotifs
        varName: "interceptedNotifs"
        defaultValue: ({})
    }

    readonly property var fleet: sharedFleet.value || ({ totals: {}, machines: [], agents: [] })
    readonly property var totals: fleet.totals || ({ machines_total: 0, machines_reachable: 0, workspaces: 0, agents: 0, blocked: 0, working: 0, idle: 0, done: 0 })
    readonly property var machines: fleet.machines || []
    readonly property var agents: fleet.agents || []
    readonly property string selectedMachine: sharedSelectedMachine.value || "all"
    readonly property string selectedStatus: sharedSelectedStatus.value || "all"
    readonly property string searchQuery: (sharedSearchQuery.value || "").trim().toLowerCase()
    readonly property bool hasActiveFilter: searchQuery.length > 0 || selectedStatus !== "all"
    readonly property int currentIntervalMs: Math.min(baseIntervalMs * Math.pow(2, sharedFailures.value), maxIntervalMs)

    property var fleetPopout: null
    property bool fleetOpenRequested: false
    property real fleetOpenRequestedAt: 0
    property bool lastPollIncludedRemote: false
    property bool pendingRemoteRefresh: false

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

    function agentMatchesSearch(ag, m, ws, q) {
        if (!q)
            return true;
        var haystack = [
            ag ? (ag.title || "") : "",
            ag ? (ag.subtitle || "") : "",
            ag ? (ag.agent || "") : "",
            ag ? (ag.pane_id || "") : "",
            ag ? (ag.cwd || "") : "",
            ag ? (ag.agent_status || "") : "",
            ag ? root.statusLabel(ag.agent_status) : "",
            ws ? (ws.label || "") : "",
            ws ? (ws.workspace_id || "") : "",
            m ? (m.label || "") : "",
            m ? (m.short_label || "") : "",
            m ? (m.id || "") : "",
            m ? (m.backend || "") : ""
        ].join(" ").toLowerCase();
        var terms = q.split(/\s+/);
        for (var i = 0; i < terms.length; i++) {
            if (terms[i] && haystack.indexOf(terms[i]) < 0)
                return false;
        }
        return true;
    }

    function filteredAgentsForWorkspace(m, ws) {
        var list = (ws && ws.agents) || [];
        var q = root.searchQuery;
        var st = root.selectedStatus;
        if (!q && st === "all")
            return list;
        var out = [];
        for (var i = 0; i < list.length; i++) {
            var ag = list[i];
            if (st !== "all" && (ag ? ag.agent_status : "") !== st)
                continue;
            if (q && !root.agentMatchesSearch(ag, m, ws, q))
                continue;
            out.push(ag);
        }
        return out;
    }

    function filteredWorkspacesForMachine(m) {
        var wsList = (m && m.workspaces) || [];
        var q = root.searchQuery;
        var st = root.selectedStatus;
        if (!q && st === "all")
            return wsList;
        var out = [];
        for (var i = 0; i < wsList.length; i++) {
            var ws = wsList[i];
            var matchedAgents = root.filteredAgentsForWorkspace(m, ws);
            if (matchedAgents.length > 0 || (st === "all" && root.includeEmptySpaces && root.agentMatchesSearch(null, m, ws, q)))
                out.push(ws);
        }
        return out;
    }

    readonly property var firstMatchingAgent: {
        var mList = root.visibleMachines || [];
        for (var i = 0; i < mList.length; i++) {
            var m = mList[i];
            var wsList = root.filteredWorkspacesForMachine(m);
            for (var j = 0; j < wsList.length; j++) {
                var agList = root.filteredAgentsForWorkspace(m, wsList[j]);
                if (agList.length > 0)
                    return agList[0];
            }
        }
        return null;
    }

    readonly property int matchingAgentCount: {
        var count = 0;
        var mList = root.visibleMachines || [];
        for (var i = 0; i < mList.length; i++) {
            var m = mList[i];
            var wsList = root.filteredWorkspacesForMachine(m);
            for (var j = 0; j < wsList.length; j++) {
                count += root.filteredAgentsForWorkspace(m, wsList[j]).length;
            }
        }
        return count;
    }

    function mergeCachedRemoteMachines(freshPayload) {
        if (!freshPayload || root.lastPollIncludedRemote || !root.includeRemoteMachines)
            return freshPayload;
        var prevMachines = (sharedFleet.value && sharedFleet.value.machines) || [];
        var remoteCached = [];
        var hcRemoteById = {};
        for (var i = 0; i < prevMachines.length; i++) {
            var pm = prevMachines[i];
            if (!pm || pm.isLocal)
                continue;
            if (pm.backend === "herdr")
                remoteCached.push(pm);
            else if (pm.backend === "hc")
                hcRemoteById[pm.id] = pm;
        }
        if (remoteCached.length === 0 && Object.keys(hcRemoteById).length === 0)
            return freshPayload;

        var localList = (freshPayload.machines || []).slice();
        var mergedMachines = [];
        var insertedRemote = false;
        for (var j = 0; j < localList.length; j++) {
            var item = localList[j];
            if (item.backend === "hc" && !insertedRemote) {
                mergedMachines = mergedMachines.concat(remoteCached);
                insertedRemote = true;
            }
            if (item.backend === "hc" && !item.isLocal && hcRemoteById[item.id]) {
                var cachedHc = hcRemoteById[item.id];
                var freshWsLen = (item.workspaces && item.workspaces.length) || 0;
                var cachedWsLen = (cachedHc.workspaces && cachedHc.workspaces.length) || 0;
                if (freshWsLen === 0 && (cachedWsLen > 0 || !cachedHc.reachable))
                    item = cachedHc;
            }
            mergedMachines.push(item);
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
            if (root.pendingRemoteRefresh) {
                root.pendingRemoteRefresh = false;
                Qt.callLater(() => root.runCollector(true));
            }
        }
    }

    // Remote SSH snapshots are queried on initial load, while the popout is open, or on manual refresh,
    // avoiding periodic background SSH fanout while keeping the local bar pill and hc spaces live.
    function runCollector(pollRemote) {
        if (!root.pluginId || !root.pluginDir)
            return;
        if (collectorProc.running) {
            if (pollRemote)
                root.pendingRemoteRefresh = true;
            return;
        }
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
        var isInitialScan = (sharedLastPoll.value === 0);
        if (!isInitialScan && now - sharedLastPoll.value < root.currentIntervalMs - 500)
            return;
        sharedLastPoll.set(now);
        root.runCollector(isInitialScan || root.isPopoutOpen());
    }

    function refreshNow() {
        if (!root.pluginId)
            return;
        sharedLastPoll.set(Date.now());
        root.runCollector(true);
    }

    function closePopoutImmediately() {
        if (root.fleetPopout && typeof root.fleetPopout.instantClose === "function") {
            root.fleetPopout.instantClose();
            return;
        }
        root.closePopout();
    }

    function focusAgent(agent) {
        if (!agent || !root.pluginDir)
            return;
        root.closePopoutImmediately();
        Quickshell.execDetached([
            "bash",
            root.focusScript,
            "agent",
            agent.backend || "herdr",
            agent.machine_id || "local",
            agent.pane_id || "",
            agent.workspace_id || "",
            agent.tab_id || "",
            agent.workspace_label || ""
        ]);
    }

    function focusWorkspace(machine, ws) {
        if (!machine || !ws || !root.pluginDir)
            return;
        var agList = ws.agents || [];
        var firstTab = agList.length > 0 ? (agList[0].tab_id || "") : "";
        var firstPane = agList.length > 0 ? (agList[0].pane_id || "") : "";
        root.closePopoutImmediately();
        Quickshell.execDetached([
            "bash",
            root.focusScript,
            "workspace",
            machine.backend || "herdr",
            machine.id || "local",
            ws.workspace_id || "",
            firstTab,
            ws.label || "",
            firstPane
        ]);
    }

    function focusHerdrWindow() {
        if (!root.pluginDir)
            return;
        root.closePopoutImmediately();
        Quickshell.execDetached(["bash", root.focusScript, "window"]);
    }

    function interceptHerdrNotifications() {
        if (!root.pluginDir || typeof NotificationService === "undefined" || !NotificationService)
            return;
        var roots = Local.HerdrFleetController.liveRoots || [];
        if (roots.length > 0 && roots[0] !== root)
            return;

        var wrappers = NotificationService.allWrappers || [];
        var seen = Object.assign({}, sharedInterceptedNotifs.value || {});
        var toReemit = [];
        for (var i = 0; i < wrappers.length; i++) {
            var w = wrappers[i];
            if (!w || !w.notification)
                continue;
            var app = (w.appName || "").toString().trim().toLowerCase();
            if (app !== "herdr")
                continue;
            var actions = w.actions || [];
            if (actions.length > 0)
                continue;
            var nid = (w.notification.id !== undefined ? w.notification.id : "").toString() + ":" + (w.time ? w.time.getTime() : 0);
            if (seen[nid])
                continue;
            seen[nid] = true;
            toReemit.push({
                wrapper: w,
                summary: (w.summary || "").toString(),
                body: (w.body || "").toString()
            });
        }
        if (toReemit.length === 0)
            return;

        sharedInterceptedNotifs.set(seen);
        Qt.callLater(() => {
            try {
                if (NotificationService._recentDedupKeys !== undefined)
                    NotificationService._recentDedupKeys = [];
            } catch (e) {}
            for (var j = 0; j < toReemit.length; j++) {
                var item = toReemit[j];
                try {
                    if (item.wrapper && NotificationService.permanentlyDismissNotification)
                        NotificationService.permanentlyDismissNotification(item.wrapper);
                    else if (item.wrapper && item.wrapper.notification)
                        item.wrapper.notification.dismiss();
                } catch (e) {}
                Quickshell.execDetached([
                    "bash",
                    root.focusScript,
                    "reemit-notification",
                    item.summary,
                    item.body
                ]);
            }
            root.refreshNow();
        });
    }

    Connections {
        target: typeof NotificationService !== "undefined" ? NotificationService : null
        ignoreUnknownSignals: true
        function onAllWrappersChanged() {
            root.interceptHerdrNotifications();
        }
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
                    name: "smart_toy"
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
                    name: "smart_toy"
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
            headerText: I18n.trFor("herdrAgentMonitor", "Herdr Agent Monitor")
            detailsText: I18n.trFor("herdrAgentMonitor", "%1 agents · %2 spaces · %3/%4 hosts").arg(root.totals.agents || 0).arg(root.totals.workspaces || 0).arg(root.totals.machines_reachable || 0).arg(root.totals.machines_total || 0)

            onParentPopoutChanged: {
                if (parentPopout)
                    root.fleetPopout = parentPopout;
            }
            Component.onCompleted: {
                if (parentPopout)
                    root.fleetPopout = parentPopout;
                root.refreshNow();
                Qt.callLater(() => searchInput.forceActiveFocus());
            }
            Connections {
                target: popout.parentPopout
                function onOpened() {
                    root.fleetOpenRequested = false;
                    root.refreshNow();
                    Qt.callLater(() => searchInput.forceActiveFocus());
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                // ── Top Interactive Status Filter Pills (blocked, working, idle, done) ──
                Flow {
                    id: statusFilterFlow
                    width: parent.width
                    spacing: Theme.spacingXS

                    Repeater {
                        model: ["blocked", "working", "idle", "done"]

                        delegate: StyledRect {
                            id: statusPill
                            required property string modelData
                            readonly property bool isSelected: root.selectedStatus === modelData
                            readonly property int statusCount: root.totals[modelData] || 0
                            readonly property color accentColor: root.statusColor(modelData)

                            height: statusPillRow.implicitHeight + Theme.spacingXS * 2
                            width: statusPillRow.implicitWidth + Theme.spacingS * 2
                            radius: Theme.cornerRadiusFull
                            color: isSelected
                                ? Theme.withAlpha(accentColor, 0.24)
                                : (statusPillMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainer)
                            border.width: isSelected ? Theme.outlineWidth : 0
                            border.color: isSelected ? accentColor : "transparent"
                            opacity: isSelected ? 1.0 : (root.selectedStatus !== "all" ? 0.65 : (statusCount > 0 ? 1.0 : 0.72))

                            Row {
                                id: statusPillRow
                                anchors.centerIn: parent
                                spacing: Theme.spacingXXS

                                DankIcon {
                                    name: root.statusIcon(statusPill.modelData)
                                    color: statusPill.accentColor
                                    size: Theme.iconSizeSmall
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: statusPill.statusCount + " " + root.statusLabel(statusPill.modelData)
                                    color: statusPill.isSelected || (statusPill.modelData === "blocked" && statusPill.statusCount > 0)
                                        ? statusPill.accentColor
                                        : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: statusPill.isSelected || (statusPill.modelData === "blocked" && statusPill.statusCount > 0)
                                        ? Font.Bold
                                        : Font.Normal
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: statusPillMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: sharedSelectedStatus.set(statusPill.isSelected ? "all" : statusPill.modelData)
                            }
                        }
                    }
                }

                // ── Live Search Bar + Quick Actions (hc toggle & refresh) ──
                Row {
                    id: searchToolbarRow
                    width: parent.width
                    spacing: Theme.spacingXS

                    StyledRect {
                        id: searchBarRect
                        width: Math.max(Theme.spacingXL * 3, parent.width - hcChip.width - refreshBtn.width - Theme.spacingXS * 2)
                        height: Theme.listItemHeight - Theme.spacingS
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainer
                        border.width: Theme.outlineWidth
                        border.color: searchInput.activeFocus ? Theme.primary : "transparent"

                        DankIcon {
                            id: searchBarIcon
                            name: "search"
                            size: Theme.iconSizeSmall
                            color: searchInput.activeFocus ? Theme.primary : Theme.surfaceVariantText
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Item {
                            anchors.left: searchBarIcon.right
                            anchors.leftMargin: Theme.spacingXS
                            anchors.right: clearSearchBtn.visible ? clearSearchBtn.left : parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom

                            StyledText {
                                visible: searchInput.text.length === 0
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: I18n.trFor("herdrAgentMonitor", "Search agents, spaces, machines, cwd…")
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            TextInput {
                                id: searchInput
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true
                                selectByMouse: true
                                color: Theme.surfaceText
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSizeSmall
                                text: sharedSearchQuery.value || ""
                                onTextChanged: {
                                    if ((sharedSearchQuery.value || "") !== text)
                                        sharedSearchQuery.set(text);
                                }
                                onAccepted: {
                                    if (root.firstMatchingAgent) {
                                        searchInput.focus = false;
                                        if (popout.parentPopout)
                                            root.fleetPopout = popout.parentPopout;
                                        root.focusAgent(root.firstMatchingAgent);
                                    }
                                }
                            }
                        }

                        StyledRect {
                            id: clearSearchBtn
                            visible: searchInput.text.length > 0
                            width: Theme.iconSizeSmall + Theme.spacingS
                            height: Theme.iconSizeSmall + Theme.spacingS
                            radius: Theme.cornerRadiusFull
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter
                            color: clearSearchMouse.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                            DankIcon {
                                anchors.centerIn: parent
                                name: "close"
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            MouseArea {
                                id: clearSearchMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    searchInput.text = "";
                                    sharedSearchQuery.set("");
                                    searchInput.forceActiveFocus();
                                }
                            }
                        }
                    }

                    // Quick toggle for Herdr Desktop App (hc)
                    StyledRect {
                        id: hcChip
                        height: searchBarRect.height
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
                        width: searchBarRect.height
                        height: searchBarRect.height
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

                // ── Machine Filter Chips (multi-row Flow so all machines & hc hosts are visible) ──
                Flow {
                    id: chipsFlow
                    visible: root.machines.length > 1
                    width: parent.width
                    spacing: Theme.spacingXS

                    // "All" chip
                    StyledRect {
                        height: allChipText.implicitHeight + Theme.spacingXS * 2
                        width: allChipText.implicitWidth + Theme.spacingM * 2
                        radius: Theme.cornerRadiusFull
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
                            visible: (root.totals.agents || 0) === 0 && !sharedRefreshing.value && !root.hasActiveFilter
                            text: I18n.trFor("herdrAgentMonitor", "No active agents across monitored machines")
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        StyledText {
                            visible: root.hasActiveFilter && root.matchingAgentCount === 0
                            text: root.searchQuery.length > 0
                                ? I18n.trFor("herdrAgentMonitor", "No agents match \"%1\"").arg(sharedSearchQuery.value || "")
                                : I18n.trFor("herdrAgentMonitor", "No %1 agents").arg(root.statusLabel(root.selectedStatus))
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        Repeater {
                            model: root.visibleMachines

                            delegate: Column {
                                id: machineBlock
                                required property var modelData
                                readonly property var visibleWorkspaces: root.filteredWorkspacesForMachine(machineBlock.modelData)
                                width: treeColumn.width
                                spacing: Theme.spacingXS
                                visible: visibleWorkspaces.length > 0 || (!root.hasActiveFilter && (!modelData.reachable || root.selectedMachine === modelData.id))

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

                                StyledText {
                                    visible: !root.hasActiveFilter && machineBlock.modelData.reachable && (!machineBlock.modelData.workspaces || machineBlock.modelData.workspaces.length === 0) && root.selectedMachine === machineBlock.modelData.id
                                    text: I18n.trFor("herdrAgentMonitor", "No active agents on this machine")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }

                                // Workspaces inside this Machine
                                Repeater {
                                    model: machineBlock.visibleWorkspaces

                                    delegate: Column {
                                        id: wsBlock
                                        required property var modelData
                                        readonly property var visibleAgents: root.filteredAgentsForWorkspace(machineBlock.modelData, wsBlock.modelData)
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
                                                    searchInput.focus = false;
                                                    if (popout.parentPopout)
                                                        root.fleetPopout = popout.parentPopout;
                                                    root.focusWorkspace(machineBlock.modelData, wsBlock.modelData);
                                                }
                                            }
                                        }

                                        // Agents inside this Space
                                        Repeater {
                                            model: wsBlock.visibleAgents

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
                                                        searchInput.focus = false;
                                                        if (popout.parentPopout)
                                                            root.fleetPopout = popout.parentPopout;
                                                        root.focusAgent(agentCard.modelData);
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
