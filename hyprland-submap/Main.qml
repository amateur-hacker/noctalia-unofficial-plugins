import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons

Item {
    id: root
    property var pluginApi: null

    readonly property string icon:
        pluginApi?.pluginSettings?.icon ||
        pluginApi?.manifest?.metadata?.defaultSettings?.icon ||
        "keyboard"
}
