import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Services.UI
import qs.Widgets

Item {
    id: root

    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""

    property var cfg: pluginApi?.pluginSettings || ({})
    property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

    readonly property string screenName: screen?.name ?? ""
    readonly property string barPosition: Settings.getBarPositionForScreen(screenName)
    readonly property bool isBarVertical: barPosition === "left" || barPosition === "right"
    readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
    readonly property real barFontSize: Style.getBarFontSizeForScreen(screenName)

    readonly property string icon: cfg.icon ?? defaults.icon ?? "keyboard"

    property string displayText: ""
    property bool isActive: false

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "submap") {
                const submapName = event.data.trim()
                if (submapName && submapName !== "") {
                    root.displayText = submapName
                    root.isActive = true
                } else {
                    root.displayText = ""
                    root.isActive = false
                }
            }
        }
    }

    visible: isActive
    z: 999

    readonly property real contentWidth: content.implicitWidth + Style.marginM * 2
    readonly property real contentHeight: capsuleHeight

    implicitWidth: contentWidth
    implicitHeight: contentHeight

    Rectangle {
        id: visualCapsule
        x: Style.pixelAlignCenter(parent.width, width)
        y: Style.pixelAlignCenter(parent.height, height)
        width: root.contentWidth
        height: root.contentHeight
        color: Style.capsuleColor
        radius: Style.radiusL
        border.color: Style.capsuleBorderColor
        border.width: Style.capsuleBorderWidth

        RowLayout {
            id: content
            anchors.centerIn: parent
            spacing: Style.marginS

            NIcon {
                icon: root.icon
                color: Color.mOnSurface
            }

            NText {
                text: root.displayText
                color: Color.mOnSurface
                pointSize: barFontSize
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
                PanelService.showContextMenu(contextMenu, root, screen);
            }
        }
    }

    NPopupContextMenu {
        id: contextMenu

        model: [
            {
                "label": I18n.tr("actions.widget-settings"),
                "action": "widget-settings",
                "icon": "settings"
            }
        ]

        onTriggered: action => {
            contextMenu.close();
            PanelService.closeContextMenu(screen);

            if (action === "widget-settings") {
                BarService.openPluginSettings(screen, pluginApi.manifest);
            }
        }
    }
}
