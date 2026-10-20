import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import org.kde.notification
import "../code/logic.js" as Logic
import "../code/look.js" as Look

PlasmoidItem {
    id: root

    readonly property string scriptPath: Qt.resolvedUrl("../code/dokploy.py").toString().replace("file://", "")
    readonly property string serverUrl: Plasmoid.configuration.serverUrl.trim().replace(/\/+$/, "")

    // Projects as {id, name, environments: [{id, name, services: [{type, id, name, status}]}]}.
    property var projects: []
    // Previous status of each service by id, to notify only on changes; null until the first check.
    property var previousStatus: null
    // Ids of services with a deploy/start/stop in progress.
    property var busyIds: ({})
    property bool loaded: false
    property date lastChecked
    property string errorText: ""
    property string actionError: ""

    // Dokploy's statuses in panel order, worst first: error = last deployment failed,
    // running = deployment in progress, done = deployed, idle = never deployed or stopped.
    // Colours come from the Appearance settings.
    readonly property var serviceStates: [
        { key: "error", label: i18n("Failed"), glyph: "cross", roundGlyph: "cross", color: root.look.colors.colorFailed,
          inPanel: Plasmoid.configuration.showFailedInPanel },
        { key: "running", label: i18n("Deploying"), glyph: "restart", roundGlyph: "restart", color: root.look.colors.colorDeploying,
          inPanel: Plasmoid.configuration.showDeployingInPanel },
        { key: "done", label: i18n("Deployed"), glyph: "check", roundGlyph: "check", color: root.look.colors.colorDeployed,
          inPanel: Plasmoid.configuration.showDeployedInPanel },
        { key: "idle", label: i18n("Idle"), glyph: "stop", roundGlyph: "stop", color: root.look.colors.colorIdle,
          inPanel: Plasmoid.configuration.showIdleInPanel },
    ]
    readonly property var typeLabels: ({
        application: i18n("Application"), compose: i18n("Compose"), postgres: i18n("PostgreSQL"), mysql: i18n("MySQL"),
        mariadb: i18n("MariaDB"), mongo: i18n("MongoDB"), redis: i18n("Redis"),
    })
    readonly property var databaseTypes: ["postgres", "mysql", "mariadb", "mongo", "redis"]

    readonly property var services: Logic.allServices(projects)
    readonly property var stateCounts: Logic.countStates(services)
    readonly property var visibleStates: Logic.visibleStates(serviceStates, stateCounts)
    // Badges (in the panel, the popup and on the desktop) show the states switched on in the
    // settings, optionally including empty ones.
    readonly property var panelStates: Logic.panelStates(serviceStates, stateCounts, Plasmoid.configuration.showZeroInPanel)
    // One group per environment that has services: {title, projectId, environmentId, services}.
    readonly property var groups: Logic.groupServices(projects, serviceStates.map(st => st.key))

    function statusKey(service) {
        return Logic.statusKey(service)
    }

    function stateOf(key) {
        return serviceStates.find(st => st.key === key)
    }

    // White or near-black, whichever reads better on the given background colour.
    function contrastText(background) {
        const c = Qt.color(background)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6 ? "#202020" : "white"
    }

    function refresh() {
        if (!serverUrl) {
            return
        }
        fetcher.connectSource("python3 -I " + Logic.shellQuote(scriptPath) + " fetch " + Logic.shellQuote(serverUrl))
    }

    function runAction(service, action) {
        const busy = Object.assign({}, busyIds)
        busy[service.id] = true
        busyIds = busy
        actionError = ""
        actions.connectSource("python3 -I " + Logic.shellQuote(scriptPath) + " " + action + " " + Logic.shellQuote(serverUrl)
            + " " + service.type + " " + Logic.shellQuote(service.id))
    }

    function serviceUrl(group, service) {
        return Logic.serviceUrl(serverUrl, group, service)
    }

    function apply(data) {
        projects = data.projects
        loaded = true
        notifyAboutFailures()
    }

    function notifyAboutFailures() {
        const result = Logic.freshFailures(services, previousStatus)
        const fresh = result.fresh
        previousStatus = result.statuses

        if (fresh.length === 0 || !Plasmoid.configuration.notifyOnFailure) {
            return
        }
        if (fresh.length === 1) {
            failureNotification.title = i18n("Dokploy: deployment of %1 failed", fresh[0].name)
            failureNotification.text = typeLabels[fresh[0].type] || fresh[0].type
        } else {
            failureNotification.title = i18np("Dokploy: %1 deployment failed", "Dokploy: %1 deployments failed", fresh.length)
            failureNotification.text = fresh.slice(0, 4).map(s => s.name).join("\n")
        }
        failureNotification.sendEvent()
    }

    onServerUrlChanged: {
        loaded = false
        projects = []
        previousStatus = null
        errorText = ""
        refresh()
    }

    P5Support.DataSource {
        id: fetcher
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.lastChecked = new Date()
            if (data["exit code"] !== 0) {
                root.errorText = data["stderr"].trim() || i18n("Fetch failed with code %1", data["exit code"])
                return
            }
            try {
                root.apply(JSON.parse(data["stdout"]))
                root.errorText = ""
            } catch (e) {
                root.errorText = i18n("Could not read Dokploy response: %1", e.message)
            }
        }
    }

    P5Support.DataSource {
        id: actions
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            const id = sourceName.split(" ").pop().replace(/'/g, "")
            const busy = Object.assign({}, root.busyIds)
            delete busy[id]
            root.busyIds = busy
            if (data["exit code"] !== 0) {
                root.actionError = data["stderr"].trim() || i18n("The action failed with code %1", data["exit code"])
            }
            root.refresh()
        }
    }

    Notification {
        id: failureNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "cloud-upload"
        urgency: Notification.HighUrgency
    }

    Timer {
        // Check every few seconds while something is deploying, so its result shows up quickly.
        interval: (root.stateCounts.running || 0) > 0 ? 5000 : Plasmoid.configuration.pollInterval * 60 * 1000
        running: root.serverUrl !== ""
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
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

    // The appearance in use: this widget's own settings, or the shared look that every
    // madebypless widget can follow (see SharedLook.qml and look.js).
    SharedLook {
        id: sharedLook
    }
    readonly property var look: Look.resolve(Plasmoid.configuration,
                                             Plasmoid.configuration.useSharedLook ? sharedLook.values : null,
                                             Logic.colorRoles)

    Plasmoid.status: (stateCounts.error || 0) > 0 ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus

    toolTipMainText: i18n("Dokploy")
    toolTipSubText: {
        if (!serverUrl) return i18n("No server configured")
        if (errorText) return errorText
        if (!loaded) return i18n("Loading…")
        if (services.length === 0) return i18n("No services")
        return visibleStates.map(st => i18n("%1 %2", stateCounts[st.key], st.label.toLowerCase())).join(" · ")
    }

    switchWidth: Kirigami.Units.gridUnit * 14
    switchHeight: Kirigami.Units.gridUnit * 14

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            enabled: root.serverUrl !== ""
            onTriggered: root.refresh()
        },
        PlasmaCore.Action {
            text: i18n("Open Dokploy")
            icon.name: "internet-web-browser"
            enabled: root.serverUrl !== ""
            onTriggered: Qt.openUrlExternally(root.serverUrl + "/dashboard/projects")
        }
    ]

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
        plus: { stroke: "M 50 26 L 50 74 M 26 50 L 74 50" },
        muted: { fill: "M 18 40 L 32 40 L 50 24 L 50 76 L 32 60 L 18 60 Z", stroke: "M 62 40 L 80 60 M 80 40 L 62 60" },
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
        property var serviceState
        property int count
        property real size
        readonly property bool rounded: root.look.badgeStyle === "rounded"

        implicitHeight: size
        implicitWidth: glyphBlock.width + countLabel.implicitWidth + size * (rounded ? 0.7 : 0.5)
        radius: rounded ? height / 2 : 2
        color: root.look.colors.colorCountBackground
        border.width: rounded ? 1.5 : 1
        border.color: serviceState.color

        Rectangle {
            id: glyphBlock
            width: parent.size
            height: parent.size
            radius: parent.rounded ? width / 2 : 2
            color: serviceState.color

            Glyph {
                anchors.centerIn: parent
                width: parent.width * 0.7
                height: width
                kind: parent.parent.rounded ? serviceState.roundGlyph : serviceState.glyph
                color: root.contrastText(serviceState.color)
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
            color: root.contrastText(root.look.colors.colorCountBackground)
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
        rowSpacing: root.look.badgeSpacing
        columnSpacing: root.look.badgeSpacing

        // Optional logo in front of the badges (panel only), chosen under Appearance.
        Kirigami.Icon {
            visible: bar.showLogo
            Layout.preferredWidth: bar.badgeSize
            Layout.preferredHeight: bar.badgeSize
            // Extra gap after the logo, on top of the badge spacing.
            Layout.rightMargin: bar.vertical ? 0 : root.look.logoSpacing
            Layout.bottomMargin: bar.vertical ? root.look.logoSpacing : 0
            source: root.customLogo || Plasmoid.icon
        }

        Repeater {
            model: bar.badgeStates
            StatusBadge {
                required property var modelData
                serviceState: modelData
                count: root.stateCounts[modelData.key] || 0
                size: bar.badgeSize
            }
        }

        PlasmaComponents.Label {
            textFormat: Text.PlainText
            visible: bar.showTotal
            text: i18n("(of %1)", root.services.length)
            font.pixelSize: bar.badgeSize * 0.6
        }
    }

    compactRepresentation: MouseArea {
        id: compact

        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        readonly property real badgeSize: Math.min(Kirigami.Units.iconSizes.smallMedium, vertical ? width : height)
        readonly property bool showTotal: Plasmoid.configuration.showTotalInPanel
        readonly property bool showBadges: root.loaded && (root.panelStates.length > 0 || showTotal)

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
            showLogo: root.look.showLogo
            vertical: compact.vertical
            badgeSize: compact.badgeSize
            opacity: root.errorText ? 0.5 : 1
        }

        // Before the first successful check, or when nothing is configured.
        Kirigami.Icon {
            anchors.centerIn: parent
            width: compact.badgeSize
            height: compact.badgeSize
            visible: !compact.showBadges
            source: root.look.showLogo && root.customLogo || Plasmoid.icon
            active: compact.containsMouse
            opacity: 0.5
        }
    }

    // One service in the popup: status dot, name, type and status, and deploy/start/stop buttons.
    component ServiceRow: PlasmaComponents.ItemDelegate {
        id: row
        property var service
        property var group
        readonly property bool busy: root.busyIds[service.id] === true
        readonly property string key: root.statusKey(service)

        Layout.fillWidth: true
        onClicked: Qt.openUrlExternally(root.serviceUrl(group, service))

        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                Layout.preferredHeight: width
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: Kirigami.Units.smallSpacing
                radius: width / 2
                color: root.stateOf(row.key).color
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: row.service.name
                    font.bold: row.key === "error"
                    elide: Text.ElideRight
                }
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: (root.typeLabels[row.service.type] || row.service.type) + " · " + root.stateOf(row.key).label
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    elide: Text.ElideRight
                }
            }

            PlasmaComponents.BusyIndicator {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                visible: row.busy || row.key === "running"
                running: visible
            }

            PlasmaComponents.ToolButton {
                visible: !row.busy && row.key !== "running"
                icon.name: "cloud-upload"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Deploy %1", row.service.name)
                onClicked: root.runAction(row.service, "deploy")
                PlasmaComponents.ToolTip.text: text
                PlasmaComponents.ToolTip.visible: hovered
            }
            PlasmaComponents.ToolButton {
                visible: !row.busy && row.key === "idle"
                icon.name: "media-playback-start"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Start %1", row.service.name)
                onClicked: root.runAction(row.service, "start")
                PlasmaComponents.ToolTip.text: text
                PlasmaComponents.ToolTip.visible: hovered
            }
            PlasmaComponents.ToolButton {
                visible: !row.busy && (row.key === "done" || row.key === "error")
                icon.name: "media-playback-stop"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Stop %1", row.service.name)
                onClicked: root.runAction(row.service, "stop")
                PlasmaComponents.ToolTip.text: text
                PlasmaComponents.ToolTip.visible: hovered
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
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        Layout.preferredHeight: Kirigami.Units.gridUnit * 28

        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                PlasmaExtras.Heading {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    level: 3
                    text: root.serverUrl ? root.serverUrl.replace(/^https?:\/\//, "") : i18n("Dokploy")
                    elide: Text.ElideRight
                }

                PlasmaComponents.ToolButton {
                    icon.name: "internet-web-browser"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Open Dokploy")
                    enabled: root.serverUrl !== ""
                    onClicked: Qt.openUrlExternally(root.serverUrl + "/dashboard/projects")
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }

                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Refresh")
                    enabled: root.serverUrl !== ""
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
                visible: root.loaded
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
                text: isNaN(root.lastChecked) ? "" : i18n("Last checked %1", root.lastChecked.toLocaleTimeString(Qt.locale(), Locale.ShortFormat))
            }
        }

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: !root.serverUrl
            iconName: "configure"
            text: i18n("No Dokploy server configured")
            helpfulAction: QQC2.Action {
                text: i18n("Configure…")
                icon.name: "configure"
                onTriggered: Plasmoid.internalAction("configure").trigger()
            }
        }

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: root.serverUrl !== "" && root.errorText !== "" && !root.loaded
            iconName: "dialog-error"
            text: i18n("Could not reach Dokploy")
            explanation: root.errorText
        }

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: root.loaded && root.services.length === 0
            iconName: "cloud-upload"
            text: i18n("No services")
        }

        PlasmaComponents.ScrollView {
            id: scroll
            anchors.fill: parent
            // Long titles are elided instead of making the list scroll sideways.
            contentWidth: availableWidth
            // Never scroll sideways. An as-needed horizontal bar would also toggle with the vertical one,
            // which changes availableWidth: a binding loop on its "visible".
            PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff
            visible: root.loaded && root.services.length > 0

            ColumnLayout {
                width: scroll.availableWidth
                spacing: 0

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    visible: root.errorText !== "" || root.actionError !== ""
                    type: Kirigami.MessageType.Warning
                    text: root.actionError || root.errorText
                }

                Repeater {
                    model: root.groups

                    ColumnLayout {
                        id: envGroup
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 0

                        GroupHeader {
                            id: envHeader
                            groupKey: "environment:" + envGroup.modelData.environmentId
                            text: i18n("%1 (%2)", envGroup.modelData.title, envGroup.modelData.services.length)
                        }
                        Repeater {
                            model: envHeader.collapsed ? [] : envGroup.modelData.services
                            ServiceRow {
                                required property var modelData
                                service: modelData
                                group: envGroup.modelData
                            }
                        }
                    }
                }
            }
        }
    }
}
