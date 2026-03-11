import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets
import qs.Services.UI

ColumnLayout {
    id: root

    property var pluginApi: null

    property string editIcon:
        pluginApi?.pluginSettings?.icon ||
        pluginApi?.manifest?.metadata?.defaultSettings?.icon ||
        "keyboard"

    spacing: Style.marginM

    RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginM

        NLabel {
            label: pluginApi?.tr("settings.icon") || "Icon"
            description: pluginApi?.tr("settings.iconDescription") || "Select an icon from library"
        }

        Item {
            Layout.fillWidth: true
        }

        RowLayout {
            spacing: Style.marginS

            NIcon {
                icon: root.editIcon
                pointSize: Style.fontSizeL
                color: Color.mPrimary
            }

            NIconButton {
                icon: "search"
                tooltipText: pluginApi?.tr("settings.browseIcons") || "Browse icons"
                onClicked: {
                    iconPicker.open();
                }
            }
        }
    }

    NIconPicker {
        id: iconPicker
        initialIcon: root.editIcon
        onIconSelected: function(iconName) {
            root.editIcon = iconName;
        }
    }

    function saveSettings() {
        if (!pluginApi) {
            Logger.e("HyprlandSubmap", "Cannot save: pluginApi is null")
            return
        }

        pluginApi.pluginSettings.icon = root.editIcon
        pluginApi.saveSettings()

        Logger.i("HyprlandSubmap", "Settings saved successfully")
    }
}
