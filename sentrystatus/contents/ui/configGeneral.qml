import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as P5Support

KCM.SimpleKCM {
    id: page

    property alias cfg_serverUrl: serverUrl.text
    property alias cfg_organization: organization.text
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_maxPages: maxPages.value
    property alias cfg_environment: environment.text
    property alias cfg_levelErrorsOnly: levelErrorsOnly.checked
    property alias cfg_categoryErrorsOnly: categoryErrorsOnly.checked
    property alias cfg_showRegressedInPanel: showRegressedInPanel.checked
    property alias cfg_notifyOnRegression: notifyOnRegression.checked
    property alias cfg_showNewInPanel: showNewInPanel.checked
    property alias cfg_showOpenInPanel: showOpenInPanel.checked
    property alias cfg_showArchivedInPanel: showArchivedInPanel.checked
    property alias cfg_showResolvedInPanel: showResolvedInPanel.checked
    property alias cfg_showZeroInPanel: showZeroInPanel.checked
    property alias cfg_showTotalInPanel: showTotalInPanel.checked
    property alias cfg_notifyOnNew: notifyOnNew.checked

    readonly property string normalizedUrl: serverUrl.text.trim().replace(/\/+$/, "")

    // null while checking, otherwise whether the keyring has a key for normalizedUrl.
    property var keyStored: null
    property bool saving: false
    property string saveError: ""

    function shellQuote(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'"
    }

    function keyringArgs() {
        return "service plasma-sentry server " + shellQuote(normalizedUrl)
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
            + " | secret-tool store --label='Sentry auth token' " + keyringArgs())
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
            Kirigami.FormData.label: i18n("Sentry server:")
            Layout.fillWidth: true
            placeholderText: "https://sentry.io"
        }

        QQC2.TextField {
            id: organization
            Kirigami.FormData.label: i18n("Organization:")
            Layout.fillWidth: true
            placeholderText: i18n("the slug in your Sentry address, e.g. my-company")
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.normalizedUrl.startsWith("http://")
            type: Kirigami.MessageType.Warning
            text: i18n("This address uses http, so the auth token would be sent unencrypted. Use https if your server supports it.")
        }

        ColumnLayout {
            Kirigami.FormData.label: i18n("Auth token:")
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true

                Kirigami.PasswordField {
                    id: apiKey
                    Layout.fillWidth: true
                    enabled: page.normalizedUrl !== "" && !page.saving
                    placeholderText: page.keyStored ? i18n("Paste a new token to replace the stored one") : i18n("Paste your Sentry auth token")
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
                    if (page.saveError) return i18n("Could not save the token: %1", page.saveError)
                    if (!page.normalizedUrl) return i18n("Enter the server address first.")
                    if (page.saving) return i18n("Saving…")
                    if (page.keyStored === null) return i18n("Checking the keyring…")
                    return page.keyStored
                        ? i18n("A token is stored in your keyring for this server.")
                        : i18n("No token stored for this server yet.")
                }
            }

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                text: i18n("Create a personal token in Sentry under User Settings → Personal Tokens (%1/settings/account/api/auth-tokens/) with the event:read and event:write scopes; event:write lets the popup resolve and archive issues. It is saved in your system keyring right away, not in the widget's settings file, and it is linked to the server address above.", page.normalizedUrl || "https://sentry.io")
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

        QQC2.SpinBox {
            id: maxPages
            Kirigami.FormData.label: i18n("List up to:")
            from: 1
            to: 20
            textFromValue: (value, locale) => i18np("%1 page of 100 issues", "%1 pages of 100 issues", value)
            valueFromText: (text, locale) => parseInt(text)
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("Unresolved issues are listed most recently seen first. The badge counts come from Sentry and cover every issue seen in the last 90 days, whatever this limit.")
        }

        QQC2.TextField {
            id: environment
            Kirigami.FormData.label: i18n("Environment:")
            Layout.fillWidth: true
            placeholderText: i18n("all environments, or e.g. production")
        }
        QQC2.CheckBox {
            id: levelErrorsOnly
            Kirigami.FormData.label: i18n("Count only:")
            text: i18n("Errors and fatals (not warnings or info)")
        }
        QQC2.CheckBox {
            id: categoryErrorsOnly
            text: i18n("Error issues (not performance or other categories)")
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("These filters apply to the list and to every badge. They are off by default so the counts match what Sentry's own issue list shows.")
        }

        QQC2.CheckBox {
            id: showNewInPanel
            Kirigami.FormData.label: i18n("Show badges:")
            text: i18n("New (first seen in the last 24 hours)")
        }
        QQC2.CheckBox {
            id: showOpenInPanel
            text: i18n("Open")
        }
        QQC2.CheckBox {
            id: showArchivedInPanel
            text: i18n("Archived (ignored)")
        }
        QQC2.CheckBox {
            id: showResolvedInPanel
            text: i18n("Resolved")
        }
        QQC2.CheckBox {
            id: showRegressedInPanel
            text: i18n("Regressed (already counted as open)")
        }
        QQC2.Switch {
            id: showZeroInPanel
            text: i18n("Also show states with no issues")
        }
        QQC2.Switch {
            id: showTotalInPanel
            text: i18n("Show the total, e.g. \"(of 42)\"")
        }

        QQC2.CheckBox {
            id: notifyOnNew
            Kirigami.FormData.label: i18n("Notifications:")
            text: i18n("Notify when a new issue appears")
        }
        QQC2.CheckBox {
            id: notifyOnRegression
            text: i18n("Notify when a resolved issue regresses")
        }
    }
}
