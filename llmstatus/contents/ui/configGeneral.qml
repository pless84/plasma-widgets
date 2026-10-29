import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property string cfg_source
    property alias cfg_ollamaUrl: ollamaUrl.text
    property alias cfg_lmstudioUrl: lmstudioUrl.text
    property alias cfg_dashboardUrl: dashboardUrl.text
    property alias cfg_showGpu: showGpu.checked
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_showStatusInPanel: showStatusInPanel.checked
    property alias cfg_showLoadedInPanel: showLoadedInPanel.checked
    property alias cfg_showZeroInPanel: showZeroInPanel.checked
    property alias cfg_notifyOnDown: notifyOnDown.checked

    // The Source box's entries, in order.
    readonly property var sources: ["ollama", "lmstudio", "dashboard"]
    readonly property int sourceIndex: Math.max(0, sources.indexOf(cfg_source))
    readonly property bool fromDashboard: cfg_source === "dashboard"
    readonly property bool fromLmStudio: cfg_source === "lmstudio"

    Kirigami.FormLayout {
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Source:")
            model: [i18n("Ollama server"), i18n("LM Studio server"), i18n("Mac server dashboard")]
            currentIndex: page.sourceIndex
            onActivated: index => {
                page.cfg_source = page.sources[index]
                // Choosing breaks the binding above; restore it so Defaults still updates the box.
                currentIndex = Qt.binding(() => page.sourceIndex)
            }
        }

        QQC2.TextField {
            id: ollamaUrl
            visible: !page.fromDashboard && !page.fromLmStudio
            Kirigami.FormData.label: i18n("Ollama address:")
            Layout.fillWidth: true
            placeholderText: "http://localhost:11434"
        }
        QQC2.TextField {
            id: lmstudioUrl
            visible: page.fromLmStudio
            Kirigami.FormData.label: i18n("LM Studio address:")
            Layout.fillWidth: true
            placeholderText: "http://localhost:1234"
        }
        QQC2.CheckBox {
            id: showGpu
            visible: !page.fromDashboard
            text: i18n("Show this computer's GPU load (NVIDIA or AMD)")
        }

        QQC2.TextField {
            id: dashboardUrl
            visible: page.fromDashboard
            Kirigami.FormData.label: i18n("Dashboard address:")
            Layout.fillWidth: true
            placeholderText: "http://192.168.1.217:8089"
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: page.fromDashboard
                ? i18n("Reads the LLM servers (Ollama and MLX), GPU and memory from the dashboard's /api/status.")
                : page.fromLmStudio
                ? i18n("Reads LM Studio's API (/api/v1/models): the loaded and downloaded models, including models on other devices reached through LM Link. Start its server with \"lms server start\".")
                : i18n("Reads Ollama's API: the version, the models loaded in memory and the installed models. Use localhost for Ollama on this computer, or another machine's address.")
        }

        QQC2.SpinBox {
            id: pollInterval
            Kirigami.FormData.label: i18n("Check every:")
            from: 5
            to: 600
            stepSize: 5
            textFromValue: (value, locale) => i18np("%1 second", "%1 seconds", value)
            valueFromText: (text, locale) => parseInt(text)
        }

        QQC2.CheckBox {
            id: showStatusInPanel
            Kirigami.FormData.label: i18n("Show badges:")
            text: i18n("Status (GPU load; red while a server is down)")
        }
        QQC2.CheckBox {
            id: showLoadedInPanel
            text: i18n("Loaded models")
        }
        QQC2.Switch {
            id: showZeroInPanel
            enabled: showLoadedInPanel.checked
            text: i18n("Also when no model is loaded")
        }

        QQC2.CheckBox {
            id: notifyOnDown
            Kirigami.FormData.label: i18n("Notifications:")
            text: i18n("Notify when an LLM server goes down")
        }
    }
}
