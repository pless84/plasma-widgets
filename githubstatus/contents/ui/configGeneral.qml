import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_notifyOnChange: notifyOnChange.checked
    property alias cfg_showOperational: showOperational.checked
    property alias cfg_showMajorOutageInPanel: showMajorOutageInPanel.checked
    property alias cfg_showPartialOutageInPanel: showPartialOutageInPanel.checked
    property alias cfg_showDegradedInPanel: showDegradedInPanel.checked
    property alias cfg_showMaintenanceInPanel: showMaintenanceInPanel.checked
    property alias cfg_showOperationalInPanel: showOperationalInPanel.checked
    property alias cfg_showZeroInPanel: showZeroInPanel.checked
    property alias cfg_showTotalInPanel: showTotalInPanel.checked

    Kirigami.FormLayout {
        QQC2.SpinBox {
            id: pollInterval
            Kirigami.FormData.label: i18n("Check every:")
            from: 1
            to: 120
            textFromValue: (value, locale) => i18np("%1 minute", "%1 minutes", value)
            valueFromText: (text, locale) => parseInt(text)
        }
        QQC2.CheckBox {
            id: notifyOnChange
            text: i18n("Notify about new, updated and resolved incidents")
        }
        QQC2.CheckBox {
            id: showOperational
            text: i18n("List operational components")
        }

        QQC2.CheckBox {
            id: showMajorOutageInPanel
            Kirigami.FormData.label: i18n("Show badges:")
            text: i18n("Major outage")
        }
        QQC2.CheckBox {
            id: showPartialOutageInPanel
            text: i18n("Partial outage")
        }
        QQC2.CheckBox {
            id: showDegradedInPanel
            text: i18n("Degraded performance")
        }
        QQC2.CheckBox {
            id: showMaintenanceInPanel
            text: i18n("Under maintenance")
        }
        QQC2.CheckBox {
            id: showOperationalInPanel
            text: i18n("Operational")
        }
        QQC2.Switch {
            id: showZeroInPanel
            text: i18n("Also show states with no components")
        }
        QQC2.Switch {
            id: showTotalInPanel
            text: i18n("Show the total, e.g. \"(of 12)\"")
        }
    }
}
