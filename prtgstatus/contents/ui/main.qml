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

    readonly property string scriptPath: Qt.resolvedUrl("../code/fetch.sh").toString().replace("file://", "")
    readonly property string serverUrl: Plasmoid.configuration.serverUrl.trim().replace(/\/+$/, "")

    property var down: []
    property var acknowledged: []
    property var warning: []
    property var unusual: []
    // Sensors of the extra states (unknown, paused, up) whose badge is switched on, keyed by state key.
    property var extraSensors: ({})
    property var seenDownIds: null
    property bool loaded: false
    property date lastChecked
    property string errorText: ""
    property bool loading: false

    // Number of sensors in each state below, keyed by state key.
    property var stateCounts: ({})
    // Per-probe counts from Logic.probeSummaries; only shown when there is more than one probe.
    property var probes: []
    // Whether the listed sensors have different priorities (otherwise stars would only be noise).
    property bool showPriority: false

    readonly property bool allGood: loaded && down.length === 0 && warning.length === 0 && unusual.length === 0

    // PRTG's sensor states in the order its status bar shows them. The colours come from the
    // Appearance settings, which default to PRTG's own so the badges match its web interface.
    // "glyph" (a glyphPaths key) is used by the square style, "roundGlyph" by the rounded style (PRTG's newer look);
    // "check" adds the small tick PRTG puts on acknowledged alarms. "inPanel" is the
    // per-state switch from the General settings. Logic.stateCodes maps PRTG's status codes to these keys.
    readonly property var sensorStates: [
        { key: "down", label: i18n("Down"), glyph: "arrowDown", roundGlyph: "cross", color: root.look.colors.colorDown,
          inPanel: Plasmoid.configuration.showDownInPanel },
        { key: "acknowledged", label: i18n("Down (acknowledged)"), glyph: "check", roundGlyph: "cross", check: true, color: root.look.colors.colorAcknowledged,
          inPanel: Plasmoid.configuration.showAcknowledgedInPanel },
        { key: "warning", label: i18n("Warning"), glyph: "exclamation", roundGlyph: "exclamation", color: root.look.colors.colorWarning,
          inPanel: Plasmoid.configuration.showWarningInPanel },
        { key: "unusual", label: i18n("Unusual"), glyph: "wave", roundGlyph: "wave", color: root.look.colors.colorUnusual,
          inPanel: Plasmoid.configuration.showUnusualInPanel },
        { key: "unknown", label: i18n("Unknown"), glyph: "question", roundGlyph: "dash", color: root.look.colors.colorUnknown,
          inPanel: Plasmoid.configuration.showUnknownInPanel },
        { key: "paused", label: i18n("Paused"), glyph: "pause", roundGlyph: "pause", color: root.look.colors.colorPaused,
          inPanel: Plasmoid.configuration.showPausedInPanel },
        { key: "up", label: i18n("Up"), glyph: "check", roundGlyph: "check", color: root.look.colors.colorUp,
          inPanel: Plasmoid.configuration.showUpInPanel },
    ]
    readonly property var visibleStates: Logic.visibleStates(sensorStates, stateCounts)
    // Badges (in the panel, the popup and on the desktop) show the states switched on in the
    // settings, optionally including empty ones.
    readonly property var panelStates: Logic.panelStates(sensorStates, stateCounts, Plasmoid.configuration.showZeroInPanel)
    readonly property int totalSensors: Logic.total(stateCounts)
    // The popup also lists these states' sensors; fetch.sh fetches them by status code.
    readonly property var extraStates: Logic.extraStates(sensorStates)
    readonly property string extraCodes: Logic.extraCodes(sensorStates)
    readonly property bool hasExtraSensors: extraStates.some(st => (extraSensors[st.key] || []).length > 0)

    // White or near-black, whichever reads better on the given background colour.
    function contrastText(background) {
        const c = Qt.color(background)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6 ? "#202020" : "white"
    }

    function stateColor(key) {
        return sensorStates.find(st => st.key === key).color
    }

    readonly property color downColor: stateColor("down")
    readonly property color warningColor: stateColor("warning")
    readonly property color unusualColor: stateColor("unusual")

    function refresh() {
        if (!serverUrl) {
            return
        }
        loading = true
        executable.exec("sh " + Logic.shellQuote(scriptPath) + " " + Logic.shellQuote(serverUrl)
                        + " " + Logic.shellQuote(extraCodes))
    }

    function sensorUrl(sensor) {
        return Logic.sensorUrl(serverUrl, sensor)
    }

    function apply(data) {
        // The root row gives the totals (the probes alone can miss sensors outside them);
        // counting every sensor is the fallback.
        probes = Logic.probeSummaries(data.probes && data.probes.probes)
        const root = Logic.probeSummaries(data.root && data.root.probes)
        stateCounts = root.length > 0 ? root[0].counts : Logic.countStates(data.all.sensors)
        const problems = Logic.splitProblems(data.problems.sensors)
        down = problems.down
        acknowledged = problems.acknowledged
        warning = problems.warning
        unusual = problems.unusual
        extraSensors = Logic.splitExtra(data.extra.sensors)
        showPriority = Logic.prioritiesDiffer(data.problems.sensors.concat(data.extra.sensors))
        loaded = true
        notifyAboutNewDown()
    }

    // "down 3 h 12 m", or "" when PRTG gave no down time
    function downSince(sensor) {
        const t = Logic.downFor(sensor)
        return t ? i18n("down %1", t) : ""
    }

    // One probe's line: its name and counts per state, flagged when all its sensors are unknown.
    function probeText(probe) {
        const counts = sensorStates.filter(st => probe.counts[st.key] > 0)
                                   .map(st => i18n("%1 %2", probe.counts[st.key], st.label.toLowerCase())).join(" · ")
        return probe.name + ": " + counts + (probe.allUnknown ? " – " + i18n("all unknown, the probe may be down") : "")
    }

    readonly property string probeLines: probes.length > 1 ? "\n" + probes.map(probeText).join("\n") : ""

    function notifyAboutNewDown() {
        const result = Logic.freshDown(down, seenDownIds, Plasmoid.configuration.notifyMinPriority)
        const fresh = result.fresh
        seenDownIds = result.seen

        if (fresh.length === 0 || !Plasmoid.configuration.notifyOnDown) {
            return
        }
        if (fresh.length === 1) {
            downNotification.title = i18n("PRTG: %1 is down", fresh[0].sensor)
            downNotification.text = [fresh[0].device, downSince(fresh[0]), fresh[0].message_raw].filter(t => t).join("\n")
        } else {
            downNotification.title = i18np("PRTG: %1 sensor went down", "PRTG: %1 sensors went down", fresh.length)
            downNotification.text = fresh.slice(0, 4).map(s => s.device + " – " + s.sensor
                                                          + (Logic.downFor(s) ? " (" + Logic.downFor(s) + ")" : "")).join("\n")
        }
        downNotification.sendEvent()
    }

    onServerUrlChanged: {
        loaded = false
        seenDownIds = null
        errorText = ""
        refresh()
    }

    onExtraCodesChanged: refresh()

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        function exec(cmd) {
            connectSource(cmd)
        }

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.loading = false
            root.lastChecked = new Date()
            if (data["exit code"] !== 0) {
                const stderr = data["stderr"].trim()
                root.errorText = stderr.includes("error: 401")
                    ? i18n("PRTG rejected the API key (401). Check the key stored in your keyring.")
                    : stderr || i18n("Fetch failed with code %1", data["exit code"])
                return
            }
            try {
                root.apply(JSON.parse(data["stdout"]))
                root.errorText = ""
            } catch (e) {
                root.errorText = i18n("Could not read PRTG response: %1", e.message)
            }
        }
    }

    Notification {
        id: downNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "network-server"
        urgency: Notification.HighUrgency
    }

    Timer {
        interval: Plasmoid.configuration.pollInterval * 60 * 1000
        running: root.serverUrl !== ""
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Plasmoid.icon: Qt.resolvedUrl("../images/logo.svg")

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

    Plasmoid.status: down.length > 0 ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus

    toolTipMainText: i18n("PRTG Status")
    toolTipSubText: {
        if (!serverUrl) return i18n("No server configured")
        if (errorText) return errorText
        if (!loaded) return i18n("Loading…")
        if (visibleStates.length > 0) {
            return visibleStates.map(st => i18n("%1 %2", stateCounts[st.key], st.label.toLowerCase())).join(" · ") + probeLines
        }
        if (allGood) return i18n("All sensors OK")
        return [
            i18n("%1 down", down.length),
            i18n("%1 warning", warning.length),
            i18n("%1 unusual", unusual.length),
            i18n("%1 acknowledged", acknowledged.length),
        ].join(" · ")
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
            text: i18n("Open PRTG Alarms")
            icon.name: "internet-web-browser"
            enabled: root.serverUrl !== ""
            onTriggered: Qt.openUrlExternally(root.serverUrl + "/alarms.htm")
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

    // A PRTG-style status badge: the state's symbol on a block of its colour, then the count.
    // Square style matches PRTG's classic status bar; rounded style its newer pill-shaped one.
    component StatusBadge: Rectangle {
        property var sensorState
        property int count
        property real size
        readonly property bool rounded: root.look.badgeStyle === "rounded"

        implicitHeight: size
        implicitWidth: glyphBlock.width + countLabel.implicitWidth + size * (rounded ? 0.7 : 0.5)
        radius: rounded ? height / 2 : 2
        color: root.look.colors.colorCountBackground
        border.width: rounded ? 1.5 : 1
        border.color: sensorState.color

        Rectangle {
            id: glyphBlock
            width: parent.size
            height: parent.size
            radius: parent.rounded ? width / 2 : 2
            color: sensorState.color

            Glyph {
                anchors.centerIn: parent
                width: parent.width * 0.7
                height: width
                kind: parent.parent.rounded ? sensorState.roundGlyph : sensorState.glyph
                color: root.contrastText(sensorState.color)
            }

            // The small green tick PRTG adds to acknowledged alarms (rounded style).
            Rectangle {
                visible: parent.parent.rounded && sensorState.check === true
                width: parent.width * 0.5
                height: width
                radius: width / 2
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: -width * 0.2
                anchors.bottomMargin: -width * 0.15
                color: root.look.colors.colorUp
                border.width: 1
                border.color: root.look.colors.colorCountBackground

                Glyph {
                    anchors.centerIn: parent
                    width: parent.width * 0.8
                    height: width
                    kind: "check"
                    color: root.contrastText(root.look.colors.colorUp)
                }
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
                sensorState: modelData
                count: root.stateCounts[modelData.key] || 0
                size: bar.badgeSize
            }
        }

        PlasmaComponents.Label {
            textFormat: Text.PlainText
            visible: bar.showTotal
            text: i18n("(of %1)", root.totalSensors)
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

    // One sensor in the popup: status dot, "device – sensor" and the PRTG message. The tooltip
    // gives the whole path (probe › group › device – sensor).
    component SensorRow: PlasmaComponents.ItemDelegate {
        property var sensor
        property color dotColor
        // Show how long it has been down (Down and Acknowledged rows).
        property bool showDownTime: false

        Layout.fillWidth: true
        onClicked: Qt.openUrlExternally(root.sensorUrl(sensor))
        PlasmaComponents.ToolTip.text: Logic.sensorPath(sensor)
        PlasmaComponents.ToolTip.visible: hovered
        PlasmaComponents.ToolTip.delay: Kirigami.Units.toolTipDelay

        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                Layout.preferredHeight: width
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: Kirigami.Units.smallSpacing
                radius: width / 2
                color: dotColor
            }

            ColumnLayout {
                Layout.fillWidth: true
                // Only the width left beside the buttons, so long lines elide instead of running under them.
                Layout.preferredWidth: 1
                spacing: 0
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: sensor.device + " – " + sensor.sensor
                    elide: Text.ElideRight
                }
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: [Logic.isPartial(sensor) ? i18n("(partial)") : "",
                           showDownTime ? root.downSince(sensor) : "",
                           root.showPriority ? Logic.stars(Logic.priorityOf(sensor)) : ""].filter(t => t).join(" · ")
                    visible: text !== ""
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    elide: Text.ElideRight
                }
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: [sensor.lastvalue, sensor.message_raw].filter(t => t && t !== "-").join(" · ")
                    visible: text !== ""
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
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

    // A section header plus its sensors; hidden when the group is empty. Clicking the header
    // collapses or expands the list, remembered per state key.
    component SensorGroup: ColumnLayout {
        id: group
        property string key
        property string title
        property var sensors: []
        property color dotColor
        property bool showDownTime: false
        // Sensors in this state according to the counts; more than are listed when the table was cut off.
        readonly property int stateTotal: root.stateCounts[key] || 0

        Layout.fillWidth: true
        spacing: 0
        visible: sensors.length > 0

        GroupHeader {
            id: header
            groupKey: group.key
            text: group.stateTotal > group.sensors.length
                ? i18n("%1 (showing %2 of %3)", group.title, group.sensors.length, group.stateTotal)
                : i18n("%1 (%2)", group.title, group.sensors.length)
        }
        Repeater {
            model: header.collapsed ? [] : sensors
            SensorRow {
                required property var modelData
                sensor: modelData
                dotColor: group.dotColor
                showDownTime: group.showDownTime
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 12
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        Layout.preferredHeight: Kirigami.Units.gridUnit * 26

        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                PlasmaExtras.Heading {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    level: 3
                    text: root.serverUrl ? root.serverUrl.replace(/^https?:\/\//, "") : i18n("PRTG Status")
                    elide: Text.ElideRight
                }

                PlasmaComponents.ToolButton {
                    icon.name: "internet-web-browser"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Open PRTG alarms")
                    enabled: root.serverUrl !== ""
                    onClicked: Qt.openUrlExternally(root.serverUrl + "/alarms.htm")
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }

                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Refresh")
                    enabled: root.serverUrl !== "" && !root.loading
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
            text: i18n("No PRTG server configured")
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
            text: i18n("Could not reach PRTG")
            explanation: root.errorText
        }

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: root.allGood && root.acknowledged.length === 0 && !root.hasExtraSensors
            iconName: "checkmark"
            text: i18n("All sensors OK")
        }

        PlasmaComponents.ScrollView {
            id: scroll
            anchors.fill: parent
            // Long titles are elided instead of making the list scroll sideways.
            contentWidth: availableWidth
            // Never scroll sideways. An as-needed horizontal bar would also toggle with the vertical one,
            // which changes availableWidth: a binding loop on its "visible".
            PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff
            visible: root.loaded && !(root.allGood && root.acknowledged.length === 0 && !root.hasExtraSensors)

            ColumnLayout {
                width: scroll.availableWidth
                spacing: 0

                Kirigami.InlineMessage {
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.smallSpacing
                    visible: root.errorText !== ""
                    type: Kirigami.MessageType.Warning
                    text: root.errorText
                }

                // Per-probe counts, when there are several probes.
                Repeater {
                    model: root.probes.length > 1 ? root.probes : []
                    PlasmaComponents.Label {
                        required property var modelData
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.smallSpacing
                        Layout.rightMargin: Kirigami.Units.smallSpacing
                        text: root.probeText(modelData)
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                        elide: Text.ElideRight
                        color: modelData.allUnknown ? root.downColor : Kirigami.Theme.textColor
                    }
                }

                SensorGroup { key: "down"; title: i18n("Down"); sensors: root.down; dotColor: root.downColor; showDownTime: true }
                SensorGroup { key: "warning"; title: i18n("Warning"); sensors: root.warning; dotColor: root.warningColor }
                SensorGroup { key: "unusual"; title: i18n("Unusual"); sensors: root.unusual; dotColor: root.unusualColor }
                SensorGroup { key: "acknowledged"; title: i18n("Acknowledged"); sensors: root.acknowledged; dotColor: Kirigami.Theme.disabledTextColor; showDownTime: true }

                // Unknown, paused and up sensors, for the states whose badge is switched on.
                Repeater {
                    model: root.extraStates
                    SensorGroup {
                        required property var modelData
                        key: modelData.key
                        title: modelData.label
                        sensors: root.extraSensors[modelData.key] || []
                        dotColor: modelData.color
                    }
                }
            }
        }
    }
}
