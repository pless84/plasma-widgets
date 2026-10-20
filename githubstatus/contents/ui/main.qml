import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import org.kde.notification
import "../code/logic.js" as Logic

PlasmoidItem {
    id: root

    readonly property string pageUrl: "https://www.githubstatus.com"
    readonly property string apiUrl: pageUrl + "/api/v2/summary.json"

    // none | minor | major | critical | maintenance | unknown
    property string indicator: "unknown"
    property string summary: i18n("Checking GitHub status…")
    property var components: []
    property var incidents: []
    property var maintenances: []
    property date lastChecked
    property string errorText: ""
    property bool loading: false

    readonly property var visibleComponents: Logic.visibleComponents(components, Plasmoid.configuration.showOperational)

    // Component states in panel order, worst first. Colours come from the Appearance settings and
    // default to githubstatus.com's own; "glyph" is the square style's symbol, "roundGlyph" the rounded one's.
    readonly property var componentStates: [
        { key: "major_outage", label: i18n("Major outage"), glyph: "cross", roundGlyph: "cross", color: Plasmoid.configuration.colorMajorOutage,
          inPanel: Plasmoid.configuration.showMajorOutageInPanel },
        { key: "partial_outage", label: i18n("Partial outage"), glyph: "exclamation", roundGlyph: "exclamation", color: Plasmoid.configuration.colorPartialOutage,
          inPanel: Plasmoid.configuration.showPartialOutageInPanel },
        { key: "degraded_performance", label: i18n("Degraded performance"), glyph: "wave", roundGlyph: "wave", color: Plasmoid.configuration.colorDegraded,
          inPanel: Plasmoid.configuration.showDegradedInPanel },
        { key: "under_maintenance", label: i18n("Under maintenance"), glyph: "gear", roundGlyph: "gear", color: Plasmoid.configuration.colorMaintenance,
          inPanel: Plasmoid.configuration.showMaintenanceInPanel },
        { key: "operational", label: i18n("Operational"), glyph: "check", roundGlyph: "check", color: Plasmoid.configuration.colorOperational,
          inPanel: Plasmoid.configuration.showOperationalInPanel },
    ]
    readonly property var stateCounts: Logic.countStates(components)
    readonly property var visibleStates: Logic.visibleStates(componentStates, stateCounts)
    // Badges (in the panel, the popup and on the desktop) show the states switched on in the
    // settings, optionally including empty ones.
    readonly property var panelStates: Logic.panelStates(componentStates, stateCounts, Plasmoid.configuration.showZeroInPanel)
    readonly property bool badgeMode: Plasmoid.configuration.badgeStyle !== "dot"

    // White or near-black, whichever reads better on the given background colour.
    function contrastText(background) {
        const c = Qt.color(background)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6 ? "#202020" : "white"
    }

    function indicatorColor(ind) {
        switch (ind) {
        case "none": return Plasmoid.configuration.colorOperational
        case "minor": return Plasmoid.configuration.colorDegraded
        case "major": return Plasmoid.configuration.colorPartialOutage
        case "critical": return Plasmoid.configuration.colorMajorOutage
        case "maintenance": return Plasmoid.configuration.colorMaintenance
        default: return Kirigami.Theme.disabledTextColor
        }
    }

    function componentColor(status) {
        const st = componentStates.find(st => st.key === status)
        return st ? st.color : Kirigami.Theme.disabledTextColor
    }

    function componentLabel(status) {
        switch (status) {
        case "operational": return i18n("Operational")
        case "degraded_performance": return i18n("Degraded performance")
        case "partial_outage": return i18n("Partial outage")
        case "major_outage": return i18n("Major outage")
        case "under_maintenance": return i18n("Under maintenance")
        default: return status
        }
    }

    function formatTime(iso) {
        return new Date(iso).toLocaleString(Qt.locale(), Locale.ShortFormat)
    }

    function refresh() {
        loading = true
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) {
                return
            }
            loading = false
            lastChecked = new Date()
            if (xhr.status !== 200) {
                errorText = xhr.status ? i18n("HTTP error %1", xhr.status) : i18n("Network error")
                return
            }
            try {
                apply(JSON.parse(xhr.responseText))
                errorText = ""
            } catch (e) {
                errorText = i18n("Could not read response: %1", e.message)
            }
        }
        xhr.open("GET", apiUrl)
        xhr.send()
    }

    function apply(data) {
        const previous = indicator
        const parsed = Logic.parseSummary(data)
        indicator = parsed.indicator
        summary = parsed.summary
        components = parsed.components
        incidents = parsed.incidents
        maintenances = parsed.maintenances

        if (Logic.indicatorChanged(previous, indicator) && Plasmoid.configuration.notifyOnChange) {
            statusNotification.text = incidents.length > 0 ? incidents[0].name : summary
            statusNotification.title = i18n("GitHub: %1", summary)
            statusNotification.sendEvent()
        }
    }

    // The logo is white, so light themes get a dark copy.
    Plasmoid.icon: Qt.resolvedUrl(Kirigami.ColorUtils.brightnessForColor(Kirigami.Theme.textColor) === Kirigami.ColorUtils.Light ? "../images/logo.svg" : "../images/logo-dark.svg")

    // The logo chosen under Appearance, or "" when none is set or its image file is gone.
    readonly property string customLogo: logoFileProbe.status === Image.Error ? "" : Plasmoid.configuration.logoIcon

    // Loads a custom logo file only to find out whether it still exists.
    Image {
        id: logoFileProbe
        visible: false
        sourceSize.width: 16
        source: {
            const logo = Plasmoid.configuration.logoIcon
            return logo.startsWith("/") ? "file://" + logo : logo.startsWith("file:") ? logo : ""
        }
    }

    Plasmoid.status: indicator === "major" || indicator === "critical"
        ? PlasmaCore.Types.NeedsAttentionStatus
        : PlasmaCore.Types.ActiveStatus

    toolTipMainText: i18n("GitHub Status")
    toolTipSubText: errorText || summary

    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 12

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refresh()
        },
        PlasmaCore.Action {
            text: i18n("Open githubstatus.com")
            icon.name: "internet-web-browser"
            onTriggered: Qt.openUrlExternally(root.pageUrl)
        }
    ]

    Notification {
        id: statusNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "vcs-branch"
    }

    Timer {
        interval: Plasmoid.configuration.pollInterval * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Badge symbols as vector paths on a 100×100 grid, so they're exactly centred and sharp at any
    // size (font glyphs like ▶ or ✕ sit off-centre). "stroke" paths are drawn as rounded lines,
    // "fill" paths are filled.
    readonly property var glyphPaths: ({
        check: { stroke: "M 25 52 L 43 70 L 76 32" },
        cross: { stroke: "M 30 30 L 70 70 M 70 30 L 30 70" },
        exclamation: { stroke: "M 50 22 L 50 54", fill: "M 42 72 A 8 8 0 1 0 58 72 A 8 8 0 1 0 42 72 Z" },
        wave: { stroke: "M 20 55 C 30 30, 42 30, 50 50 C 58 70, 70 70, 80 45" },
        dash: { stroke: "M 24 50 L 40 50 M 60 50 L 76 50" },
        question: { stroke: "M 37 37 C 37 21, 63 21, 63 37 C 63 49, 50 48, 50 58", fill: "M 43 74 A 7 7 0 1 0 57 74 A 7 7 0 1 0 43 74 Z" },
        arrowDown: { stroke: "M 50 24 L 50 74 M 31 55 L 50 74 L 69 55" },
        pause: { fill: "M 30 26 L 44 26 L 44 74 L 30 74 Z M 56 26 L 70 26 L 70 74 L 56 74 Z" },
        stop: { fill: "M 31 31 L 69 31 L 69 69 L 31 69 Z" },
        play: { fill: "M 36 25 L 76 50 L 36 75 Z" },
        restart: { stroke: "M 71 40 A 23 23 0 1 0 73 58", fill: "M 60 26 L 82 28 L 74 48 Z" },
        gear: { stroke: "M 50 34 A 16 16 0 1 1 49.9 34 M 50 14 L 50 24 M 50 76 L 50 86 M 14 50 L 24 50 M 76 50 L 86 50 M 25 25 L 32 32 M 68 68 L 75 75 M 75 25 L 68 32 M 25 75 L 32 68" },
    })

    // One badge symbol from glyphPaths, scaled to the item's size.
    component Glyph: Item {
        id: glyph
        property string kind
        property color color
        readonly property var paths: root.glyphPaths[kind] || ({})

        Shape {
            width: 100
            height: 100
            scale: glyph.width / 100
            transformOrigin: Item.TopLeft
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: glyph.paths.stroke ? glyph.color : "transparent"
                strokeWidth: 12
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: glyph.paths.stroke || "M 0 0" }
            }
            ShapePath {
                strokeColor: "transparent"
                fillColor: glyph.paths.fill ? glyph.color : "transparent"
                PathSvg { path: glyph.paths.fill || "M 0 0" }
            }
        }
    }

    // A status badge: the state's symbol on a block of its colour, then the count.
    // Square or rounded (pill-shaped), as chosen under Appearance.
    component StatusBadge: Rectangle {
        property var componentState
        property int count
        property real size
        readonly property bool rounded: Plasmoid.configuration.badgeStyle === "rounded"

        implicitHeight: size
        implicitWidth: glyphBlock.width + countLabel.implicitWidth + size * (rounded ? 0.7 : 0.5)
        radius: rounded ? height / 2 : 2
        color: Plasmoid.configuration.colorCountBackground
        border.width: rounded ? 1.5 : 1
        border.color: componentState.color

        Rectangle {
            id: glyphBlock
            width: parent.size
            height: parent.size
            radius: parent.rounded ? width / 2 : 2
            color: componentState.color

            Glyph {
                anchors.centerIn: parent
                width: parent.width * 0.7
                height: width
                kind: parent.parent.rounded ? componentState.roundGlyph : componentState.glyph
                color: root.contrastText(componentState.color)
            }
        }

        PlasmaComponents.Label {
            textFormat: Text.PlainText
            id: countLabel
            anchors.left: glyphBlock.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: count
            color: root.contrastText(Plasmoid.configuration.colorCountBackground)
            font.pixelSize: parent.size * 0.6
        }
    }

    // A row (or column, in a vertical panel) of status badges, optionally followed by "(of N)".
    component BadgeBar: GridLayout {
        id: bar
        property real badgeSize
        property bool vertical: false
        property var badgeStates: root.visibleStates
        property bool showTotal: false
        property bool showLogo: false
        readonly property int itemCount: badgeStates.length + (showTotal ? 1 : 0) + (showLogo ? 1 : 0)

        flow: vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
        rows: vertical ? Math.max(itemCount, 1) : 1
        columns: vertical ? 1 : Math.max(itemCount, 1)
        rowSpacing: Plasmoid.configuration.badgeSpacing
        columnSpacing: Plasmoid.configuration.badgeSpacing

        // Optional logo in front of the badges (panel only), chosen under Appearance.
        Kirigami.Icon {
            visible: bar.showLogo
            Layout.preferredWidth: bar.badgeSize
            Layout.preferredHeight: bar.badgeSize
            source: root.customLogo || Plasmoid.icon
        }

        Repeater {
            model: bar.badgeStates
            StatusBadge {
                required property var modelData
                componentState: modelData
                count: root.stateCounts[modelData.key] || 0
                size: bar.badgeSize
            }
        }

        PlasmaComponents.Label {
            textFormat: Text.PlainText
            visible: bar.showTotal
            text: i18n("(of %1)", root.components.length)
            font.pixelSize: bar.badgeSize * 0.6
        }
    }

    compactRepresentation: MouseArea {
        id: compact

        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        readonly property real badgeSize: Math.min(Kirigami.Units.iconSizes.smallMedium, vertical ? width : height)
        readonly property bool showTotal: Plasmoid.configuration.showTotalInPanel
        readonly property bool showBadges: root.badgeMode && root.components.length > 0
            && (root.panelStates.length > 0 || showTotal)

        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) {
                root.refresh()
            } else {
                root.expanded = !root.expanded
            }
        }

        Layout.minimumWidth: vertical ? 0 : (showBadges ? badges.implicitWidth : badgeSize)
        Layout.minimumHeight: vertical ? (showBadges ? badges.implicitHeight : badgeSize) : 0

        BadgeBar {
            id: badges
            anchors.centerIn: parent
            visible: compact.showBadges
            badgeStates: root.panelStates
            showTotal: compact.showTotal
            showLogo: Plasmoid.configuration.showLogo
            vertical: compact.vertical
            badgeSize: compact.badgeSize
            opacity: root.errorText ? 0.5 : 1
        }

        // "Icon with status dot" style, and the fallback before the first check.
        Item {
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height)
            height: width
            visible: !compact.showBadges

            Kirigami.Icon {
                anchors.fill: parent
                source: Plasmoid.configuration.showLogo && root.customLogo || Plasmoid.icon
                active: compact.containsMouse
            }

            Rectangle {
                width: Math.max(Kirigami.Units.smallSpacing * 2, parent.width * 0.35)
                height: width
                radius: width / 2
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                color: root.errorText ? root.indicatorColor("unknown") : root.indicatorColor(root.indicator)
                border.width: 1
                border.color: Kirigami.Theme.backgroundColor
            }
        }
    }

    function isCollapsed(key) {
        return Plasmoid.configuration.collapsedGroups.includes(key)
    }

    function toggleCollapsed(key) {
        Plasmoid.configuration.collapsedGroups = Logic.toggled(Array.from(Plasmoid.configuration.collapsedGroups), key)
    }

    // A popup section header that collapses or expands its list when clicked, remembered per
    // groupKey. The list's Repeater shows nothing while "collapsed" is set.
    component GroupHeader: Kirigami.ListSectionHeader {
        id: groupHeader
        property string groupKey
        readonly property bool collapsed: root.isCollapsed(groupKey)

        Layout.fillWidth: true
        icon.name: collapsed ? (Qt.application.layoutDirection === Qt.RightToLeft ? "arrow-left" : "arrow-right") : "arrow-down"
        icon.width: Kirigami.Units.iconSizes.small
        icon.height: Kirigami.Units.iconSizes.small
        hoverEnabled: true
        onClicked: root.toggleCollapsed(groupKey)
        Accessible.name: collapsed ? i18n("Expand %1", text) : i18n("Collapse %1", text)
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20
        Layout.preferredHeight: Kirigami.Units.gridUnit * 24

        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                Rectangle {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: width
                    radius: width / 2
                    color: root.errorText ? root.indicatorColor("unknown") : root.indicatorColor(root.indicator)
                }

                PlasmaExtras.Heading {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    level: 3
                    text: root.summary
                    elide: Text.ElideRight
                }

                PlasmaComponents.ToolButton {
                    icon.name: "internet-web-browser"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Open githubstatus.com")
                    onClicked: Qt.openUrlExternally(root.pageUrl)
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }

                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Refresh")
                    enabled: !root.loading
                    onClicked: root.refresh()
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }
            }
        }

        footer: ColumnLayout {
            spacing: 0

            BadgeBar {
                Layout.margins: Kirigami.Units.smallSpacing
                Layout.bottomMargin: 0
                visible: root.badgeMode && root.components.length > 0
                badgeSize: Kirigami.Units.iconSizes.small * 1.25
                badgeStates: root.panelStates
                showTotal: Plasmoid.configuration.showTotalInPanel
            }

            PlasmaComponents.Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                opacity: 0.7
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
                text: root.errorText
                    ? root.errorText
                    : (isNaN(root.lastChecked) ? "" : i18n("Last checked %1", root.lastChecked.toLocaleTimeString(Qt.locale(), Locale.ShortFormat)))
            }
        }

        PlasmaComponents.ScrollView {
            id: scroll
            anchors.fill: parent
            // Long titles are elided instead of making the list scroll sideways.
            contentWidth: availableWidth
            // Never scroll sideways. An as-needed horizontal bar would also toggle with the vertical one,
            // which changes availableWidth: a binding loop on its "visible".
            PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff

            ColumnLayout {
                width: scroll.availableWidth
                spacing: Kirigami.Units.smallSpacing

                GroupHeader {
                    id: incidentHeader
                    groupKey: "incidents"
                    visible: root.incidents.length + root.maintenances.length > 0
                    text: i18n("Active incidents")
                }

                Repeater {
                    id: incidentRepeater
                    model: incidentHeader.collapsed ? [] : root.incidents.concat(root.maintenances)

                    PlasmaComponents.ItemDelegate {
                        required property var modelData
                        Layout.fillWidth: true
                        onClicked: Qt.openUrlExternally(modelData.shortlink)
                        contentItem: ColumnLayout {
                            spacing: 0
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                text: modelData.name
                                wrapMode: Text.WordWrap
                                font.bold: true
                                color: root.indicatorColor(modelData.impact === "none" ? "maintenance" : modelData.impact)
                            }
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                text: i18n("%1 · updated %2", modelData.status, root.formatTime(modelData.updated_at))
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                            }
                        }
                    }
                }

                GroupHeader {
                    id: componentHeader
                    groupKey: "components"
                    visible: root.visibleComponents.length > 0
                    text: i18n("Components")
                }

                Repeater {
                    id: componentRepeater
                    model: componentHeader.collapsed ? [] : root.visibleComponents

                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.largeSpacing
                        Layout.rightMargin: Kirigami.Units.largeSpacing
                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                            Layout.preferredHeight: width
                            radius: width / 2
                            color: root.componentColor(modelData.status)
                        }
                        PlasmaComponents.Label {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            text: modelData.name
                            elide: Text.ElideRight
                        }
                        PlasmaComponents.Label {
                            textFormat: Text.PlainText
                            text: root.componentLabel(modelData.status)
                            opacity: 0.7
                        }
                    }
                }

                PlasmaExtras.PlaceholderMessage {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.gridUnit * 2
                    visible: !incidentHeader.visible && !componentHeader.visible
                    iconName: root.loading ? "view-refresh" : "checkmark"
                    text: root.loading ? i18n("Loading…") : i18n("All components operational")
                }
            }
        }
    }
}
