import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "herdrAgentMonitor"

    StyledText {
        width: parent.width
        text: I18n.trFor("herdrAgentMonitor", "Herdr Agent Monitor")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.trFor("herdrAgentMonitor", "Monitors herdr agents and workspaces across your local machine, remote SSH machines (`herdr machine list`), and optionally the Herdr Desktop App (`hc` / `herdr-core`). Left-click opens the popout, right-click refreshes, middle-click focuses the herdr window.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    ToggleSetting {
        settingKey: "includeRemoteMachines"
        label: I18n.trFor("herdrAgentMonitor", "Monitor remote machines (SSH)")
        description: I18n.trFor("herdrAgentMonitor", "Queries all enabled machines in `herdr machine list` via `herdr --machine <host> api snapshot`")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "includeHerdrCore"
        label: I18n.trFor("herdrAgentMonitor", "Include Herdr Desktop App (hc)")
        description: I18n.trFor("herdrAgentMonitor", "Queries `herdr-app ls`, `herdr-core` state, and `hc ls --json` across local and remote `hc` machines")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "includeEmptySpaces"
        label: I18n.trFor("herdrAgentMonitor", "Show spaces without active agents")
        description: I18n.trFor("herdrAgentMonitor", "Includes open workspaces in the tree even when they have no running agent")
        defaultValue: false
    }

    SelectionSetting {
        settingKey: "pillDisplayMode"
        label: I18n.trFor("herdrAgentMonitor", "Bar pill label")
        description: I18n.trFor("herdrAgentMonitor", "What counter to display next to the bar icon")
        options: [
            { label: I18n.trFor("herdrAgentMonitor", "Total agents (highlighted when active)"), value: "total" },
            { label: I18n.trFor("herdrAgentMonitor", "Breakdown (blocked / working / total)"), value: "breakdown" },
            { label: I18n.trFor("herdrAgentMonitor", "Blocked + working only"), value: "activeOnly" },
            { label: I18n.trFor("herdrAgentMonitor", "Icon only"), value: "iconOnly" }
        ]
        defaultValue: "breakdown"
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: I18n.trFor("herdrAgentMonitor", "Refresh interval")
        description: I18n.trFor("herdrAgentMonitor", "How often to poll machine snapshots (seconds)")
        defaultValue: 15
        minimum: 10
        maximum: 120
        unit: I18n.trFor("herdrAgentMonitor", "sec")
        leftIcon: "schedule"
    }
}
