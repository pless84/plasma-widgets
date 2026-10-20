import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_serverUrl: serverUrl.text
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_notifyOnOffline: notifyOnOffline.checked
    property alias cfg_notifyOnFailedJob: notifyOnFailedJob.checked
    property alias cfg_showOfflineInPanel: showOfflineInPanel.checked
    property alias cfg_showBusyInPanel: showBusyInPanel.checked
    property alias cfg_showIdleInPanel: showIdleInPanel.checked
    property alias cfg_showZeroInPanel: showZeroInPanel.checked
    property alias cfg_showTotalInPanel: showTotalInPanel.checked
    property alias cfg_showJobsInPanel: showJobsInPanel.checked
    property alias cfg_notifyOnJobProblem: notifyOnJobProblem.checked

    Kirigami.FormLayout {
        QQC2.TextField {
            id: serverUrl
            Kirigami.FormData.label: i18n("Runner dashboard:")
            Layout.fillWidth: true
            placeholderText: "http://192.168.1.217:8089"
        }
        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            text: i18n("The widget reads the dashboard's /api/status.")
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
            id: showOfflineInPanel
            Kirigami.FormData.label: i18n("Show badges:")
            text: i18n("Offline")
        }
        QQC2.CheckBox {
            id: showBusyInPanel
            text: i18n("Busy (running a job)")
        }
        QQC2.CheckBox {
            id: showIdleInPanel
            text: i18n("Idle")
        }
        QQC2.Switch {
            id: showZeroInPanel
            text: i18n("Also show states with no runners")
        }
        QQC2.Switch {
            id: showTotalInPanel
            text: i18n("Show the total, e.g. \"(of 2)\"")
        }
        QQC2.CheckBox {
            id: showJobsInPanel
            text: i18n("Scheduled jobs, while one has failed or missed its run")
        }

        QQC2.CheckBox {
            id: notifyOnOffline
            Kirigami.FormData.label: i18n("Notifications:")
            text: i18n("Notify when a runner goes offline")
        }
        QQC2.CheckBox {
            id: notifyOnFailedJob
            text: i18n("Notify when a job fails")
        }
        QQC2.CheckBox {
            id: notifyOnJobProblem
            text: i18n("Notify when a scheduled job fails or misses its run")
        }
    }
}
