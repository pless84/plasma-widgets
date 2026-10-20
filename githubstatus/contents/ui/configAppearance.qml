import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kquickcontrols as KQuickControls
import org.kde.iconthemes as KIconThemes

KCM.SimpleKCM {
    id: page

    property string cfg_badgeStyle
    property string cfg_badgeStyleDefault
    property int cfg_badgeSpacing
    property int cfg_badgeSpacingDefault
    property bool cfg_showLogo
    property bool cfg_showLogoDefault
    property string cfg_logoIcon
    property string cfg_logoIconDefault

    // The widget's own icon, used as the logo until another one is chosen.
    readonly property string defaultLogo: Qt.resolvedUrl(Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.textColor) === Kirigami.ColorUtils.Light ? "../images/logo.svg" : "../images/logo-dark.svg")

    property QtObject logoDialog: KIconThemes.IconDialog {
        title: i18n("Choose a Logo")
        onIconNameChanged: if (iconName) page.cfg_logoIcon = iconName
    }
    property color cfg_colorMajorOutage
    property color cfg_colorMajorOutageDefault
    property color cfg_colorPartialOutage
    property color cfg_colorPartialOutageDefault
    property color cfg_colorDegraded
    property color cfg_colorDegradedDefault
    property color cfg_colorMaintenance
    property color cfg_colorMaintenanceDefault
    property color cfg_colorOperational
    property color cfg_colorOperationalDefault
    property color cfg_colorCountBackground
    property color cfg_colorCountBackgroundDefault

    // One row per colour setting: the config key (without "cfg_") and its label.
    readonly property var colorSettings: [
        { key: "colorMajorOutage", label: i18n("Major outage:") },
        { key: "colorPartialOutage", label: i18n("Partial outage:") },
        { key: "colorDegraded", label: i18n("Degraded performance:") },
        { key: "colorMaintenance", label: i18n("Under maintenance:") },
        { key: "colorOperational", label: i18n("Operational:") },
        { key: "colorCountBackground", label: i18n("Count background:") }
    ]

    Kirigami.FormLayout {
        QQC2.ComboBox {
            readonly property var styles: ["square", "rounded", "dot"]
            Kirigami.FormData.label: i18n("Badge style:")
            model: [i18n("Square"), i18n("Rounded"), i18n("Icon with status dot")]
            currentIndex: Math.max(styles.indexOf(page.cfg_badgeStyle), 0)
            onActivated: index => page.cfg_badgeStyle = styles[index]
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Badge spacing:")

            QQC2.Slider {
                from: 0
                to: 16
                stepSize: 1
                snapMode: QQC2.Slider.SnapAlways
                value: page.cfg_badgeSpacing
                onMoved: page.cfg_badgeSpacing = value
            }

            QQC2.Label {
                text: i18n("%1 px", page.cfg_badgeSpacing)
            }
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Logo:")
            text: i18n("Show a logo in front of the badges in the panel")
            checked: page.cfg_showLogo
            onToggled: page.cfg_showLogo = checked
        }

        RowLayout {
            enabled: page.cfg_showLogo

            QQC2.Button {
                icon.name: page.cfg_logoIcon || page.defaultLogo
                text: i18n("Choose…")
                onClicked: page.logoDialog.open()
                QQC2.ToolTip.text: i18n("Pick an icon, or an image file such as a downloaded logo")
                QQC2.ToolTip.visible: hovered
            }

            QQC2.ToolButton {
                icon.name: "edit-reset"
                display: QQC2.AbstractButton.IconOnly
                text: i18n("Use the widget's own icon")
                enabled: page.cfg_logoIcon !== ""
                onClicked: page.cfg_logoIcon = ""
                QQC2.ToolTip.text: text
                QQC2.ToolTip.visible: hovered
            }
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Colours")
        }

        Repeater {
            model: page.colorSettings

            RowLayout {
                required property var modelData
                readonly property string key: "cfg_" + modelData.key
                readonly property bool isDefault: Qt.colorEqual(page[key], page[key + "Default"])

                Kirigami.FormData.label: modelData.label

                KQuickControls.ColorButton {
                    color: page[key]
                    dialogTitle: modelData.label
                    showAlphaChannel: false
                    onAccepted: picked => page[key] = picked
                }

                QQC2.ToolButton {
                    icon.name: "edit-reset"
                    display: QQC2.AbstractButton.IconOnly
                    text: i18n("Reset to default")
                    enabled: !isDefault
                    onClicked: page[key] = page[key + "Default"]
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                }
            }
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("The colours are also used for the status dot and the component list. The symbol and number on each badge switch between white and dark text to stay readable on the colour you pick.")
        }
    }
}
