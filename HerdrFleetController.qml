pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

// Shared IPC controller so `dms ipc call herdrAgentMonitor toggle|open|close|refresh|status`
// targets the widget instance on the focused monitor.
QtObject {
    id: root

    property var liveRoots: []

    function registerRoot(widget) {
        if (!widget || liveRoots.indexOf(widget) >= 0)
            return;
        liveRoots = liveRoots.concat([widget]);
    }

    function unregisterRoot(widget) {
        var idx = liveRoots.indexOf(widget);
        if (idx < 0)
            return;
        var next = liveRoots.slice();
        next.splice(idx, 1);
        liveRoots = next;
    }

    function screenName(widget) {
        return widget?.parentScreen?.name || "";
    }

    function focusedRoot() {
        var focusedScreen = BarWidgetService.getFocusedScreenName();
        if (focusedScreen) {
            for (var i = 0; i < liveRoots.length; i++) {
                if (screenName(liveRoots[i]) === focusedScreen)
                    return liveRoots[i];
            }
        }
        return liveRoots.length ? liveRoots[0] : null;
    }

    property IpcHandler ipcHandler: IpcHandler {
        target: "herdrAgentMonitor"

        function open(): string {
            var widget = root.focusedRoot();
            return widget ? widget.openFromIpc() : "HERDR_UNAVAILABLE";
        }

        function close(): string {
            var widget = root.focusedRoot();
            return widget ? widget.closeFromIpc() : "HERDR_UNAVAILABLE";
        }

        function toggle(): string {
            var widget = root.focusedRoot();
            return widget ? widget.toggleFromIpc() : "HERDR_UNAVAILABLE";
        }

        function refresh(): string {
            var widget = root.focusedRoot();
            return widget ? widget.refreshFromIpc() : "HERDR_UNAVAILABLE";
        }

        function status(): string {
            var widget = root.focusedRoot();
            return widget ? widget.statusFromIpc() : "HERDR_UNAVAILABLE";
        }
    }
}
