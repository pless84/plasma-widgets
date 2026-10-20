import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as P5Support

KCM.SimpleKCM {
    id: page

    property alias cfg_serverUrl: serverUrl.text
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_notifyOnDown: notifyOnDown.checked
    property alias cfg_notifyMinPriority: notifyMinPriority.value
    property alias cfg_showDownInPanel: showDownInPanel.checked
    property alias cfg_showAcknowledgedInPanel: showAcknowledgedInPanel.checked
    property alias cfg_showWarningInPanel: showWarningInPanel.checked
    property alias cfg_showUnusualInPanel: showUnusualInPanel.checked
    property alias cfg_showUnknownInPanel: showUnknownInPanel.checked
    property alias cfg_showPausedInPanel: showPausedInPanel.checked
    property alias cfg_showUpInPanel: showUpInPanel.checked
    property alias cfg_showZeroInPanel: showZeroInPanel.checked
    property alias cfg_showTotalInPanel: showTotalInPanel.checked

    readonly property string normalizedUrl: serverUrl.text.trim().replace(/\/+$/, "")

    // null while checking, otherwise whether the keyring has a key for normalizedUrl.
    property var keyStored: null
    property bool saving: false
    property string saveError: ""

    function shellQuote(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'"
    }

    function keyringArgs() {
        return "service plasma-prtg server " + shellQuote(normalizedUrl)
    }

    function checkKey() {
        keyStored = null
        if (normalizedUrl) {
            // Prints only the key's length, never the key itself.
            executable.run("check", "secret-tool lookup " + keyringArgs() + " | wc -c")
        }
    }

    // The key reaches secret-tool on stdin via the shell's builtin printf, so it is only
    // part of the shell's own command line for the moment the save takes.
    function saveKey() {
        const key = apiKey.text.trim()
        if (!key || !normalizedUrl) {
            return
        }
        saving = true
        saveError = ""
        executable.run("save", "printf '%s' " + shellQuote(key)
            + " | secret-tool store --label='PRTG API key' " + keyringArgs())
    }

    onNormalizedUrlChanged: checkTimer.restart()
    Component.onCompleted: checkKey()

    Timer {
        id: checkTimer
        interval: 500
        onTriggered: page.checkKey()
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        property var purposes: ({})

        function run(purpose, cmd) {
            purposes[cmd] = purpose
            connectSource(cmd)
        }

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            const purpose = purposes[sourceName]
            delete purposes[sourceName]

            if (purpose === "check") {
                page.keyStored = parseInt(data["stdout"]) > 0
            } else if (purpose === "save") {
                page.saving = false
                if (data["exit code"] === 0) {
                    apiKey.text = ""
                    page.checkKey()
                } else {
                    page.saveError = data["stderr"].trim() || i18n("secret-tool exited with code %1", data["exit code"])
                }
            }
        }
    }

    Kirigami.FormLayout {
        QQC2.TextField {
            id: serverUrl
            Kirigami.FormData.label: i18n("PRTG server:")
            Layout.fillWidth: true
            placeholderText: "https://prtg.example.com"
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.normalizedUrl.startsWith("http://")
            type: Kirigami.MessageType.Warning
            text: i18n("This address uses http, so the API key would be sent unencrypted. Use https if your server supports it.")
        }

        ColumnLayout {
            Kirigami.FormData.label: i18n("API key:")
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true

                Kirigami.PasswordField {
                    id: apiKey
                    Layout.fillWidth: true
                    enabled: page.normalizedUrl !== "" && !page.saving
                    placeholderText: page.keyStored ? i18n("Paste a new key to replace the stored one") : i18n("Paste your PRTG API key")
                    onAccepted: page.saveKey()
                }

                QQC2.Button {
                    text: i18n("Save to Keyring")
                    icon.name: "document-save"
                    enabled: apiKey.text.trim() !== "" && page.normalizedUrl !== "" && !page.saving
                    onClicked: page.saveKey()
                }
            }

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                color: page.saveError ? Kirigami.Theme.negativeTextColor
                    : page.keyStored === true ? Kirigami.Theme.positiveTextColor
                    : Kirigami.Theme.disabledTextColor
                text: {
                    if (page.saveError) return i18n("Could not save the key: %1", page.saveError)
                    if (!page.normalizedUrl) return i18n("Enter the server address first.")
                    if (page.saving) return i18n("Saving…")
                    if (page.keyStored === null) return i18n("Checking the keyring…")
                    return page.keyStored
                        ? i18n("A key is stored in your keyring for this server.")
                        : i18n("No key stored for this server yet.")
                }
            }

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                text: i18n("Create a read-only key in PRTG under Setup → Account Settings → API Keys. The key is saved in your system keyring right away, not in the widget's settings file, and it is linked to the server address above.")
            }
        }

        QQC2.SpinBox {
            id: pollInterval
            Kirigami.FormData.label: i18n("Check every:")
            from: 1
            to: 60
            textFromValue: (value, locale) => i18np("%1 minute", "%1 minutes", value)
            valueFromText: (text, locale) => parseInt(text)
        }

        QQC2.CheckBox {
            id: showDownInPanel
            Kirigami.FormData.label: i18n("Show badges:")
            text: i18n("Down")
        }
        QQC2.CheckBox {
            id: showAcknowledgedInPanel
            text: i18n("Down (acknowledged)")
        }
        QQC2.CheckBox {
            id: showWarningInPanel
            text: i18n("Warning")
        }
        QQC2.CheckBox {
            id: showUnusualInPanel
            text: i18n("Unusual")
        }
        QQC2.CheckBox {
            id: showUnknownInPanel
            text: i18n("Unknown")
        }
        QQC2.CheckBox {
            id: showPausedInPanel
            text: i18n("Paused")
        }
        QQC2.CheckBox {
            id: showUpInPanel
            text: i18n("Up")
        }
        QQC2.Switch {
            id: showZeroInPanel
            text: i18n("Also show states with no sensors")
        }
        QQC2.Switch {
            id: showTotalInPanel
            text: i18n("Show the total, e.g. \"(of 919)\"")
        }

        QQC2.CheckBox {
            id: notifyOnDown
            text: i18n("Notify when sensors go down")
        }

        QQC2.SpinBox {
            id: notifyMinPriority
            enabled: notifyOnDown.checked
            Kirigami.FormData.label: i18n("Notify from priority:")
            from: 1
            to: 5
            textFromValue: (value, locale) => value === 1 ? i18n("1 (all sensors)") : i18n("%1 or higher", value)
            valueFromText: (text, locale) => parseInt(text)
        }
    }
}
