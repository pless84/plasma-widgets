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
import "../code/look.js" as Look

PlasmoidItem {
    id: root

    readonly property string serverUrl: Plasmoid.configuration.serverUrl.trim().replace(/\/+$/, "")
    readonly property string apiUrl: serverUrl + "/api/status"

    // The dashboard's /api/status: {now, host: {hostname, os, load, cpus, uptime, disk_free_gb,
    // disk_total_gb}, runners: [{dir, name, repo, repo_url, status, job, history, problems, …}]}.
    property var host: null
    property var runners: []
    // The server's clock at the last check, so durations don't depend on this machine's clock.
    property real serverNow: 0
    // What Logic.changes() returned last time; null until the first check.
    property var snapshot: null
    property bool loaded: false
    property date lastChecked
    property string errorText: ""
    property bool loading: false
    // The dashboard's "llm" block ({gpu, memory, ollama, mlx}), or null when it has none.
    property var llm: null
    // What Logic.llmChanges() returned last time; null until the first check.
    property var llmSnapshot: null

    // The dashboard's "jobs" list (scheduled LaunchAgents, e.g. a nightly backup); empty on older dashboards.
    property var jobs: []
    // What Logic.jobChanges() returned last time; null until the first check.
    property var jobSnapshot: null
    readonly property var sortedJobs: Logic.sortJobs(jobs)
    readonly property int failingJobCount: Logic.failingJobs(jobs).length
    // The panel's jobs badge: only while a scheduled job has failed or missed its run.
    readonly property var jobsBadge: failingJobCount > 0 && Plasmoid.configuration.showJobsInPanel
        ? { key: "jobs", glyph: "cross", roundGlyph: "cross", color: root.look.colors.colorOffline, count: failingJobCount }
        : null
    readonly property string jobsSummary: failingJobCount > 0
        ? i18np("%1 scheduled job failing", "%1 scheduled jobs failing", failingJobCount) : ""
    // The badges after the runner badges: local LLMs, then failing jobs.
    readonly property var extraBadges: [llmBadge, jobsBadge].filter(b => b)

    readonly property var llmServers: Logic.llmServers(llm)
    readonly property string llmState: Logic.llmState(llm)
    // The panel's LLM badge: the GPU load, coloured and marked by the servers' state.
    readonly property var llmBadge: {
        if (!llmState || !Plasmoid.configuration.showLlmInPanel) return null
        const glyph = llmState === "down" ? "cross" : llmState === "busy" ? "play" : "check"
        return {
            key: "llm", glyph: glyph, roundGlyph: glyph,
            count: llm.gpu && llm.gpu.util !== null && llm.gpu.util !== undefined ? llm.gpu.util + "%" : "–",
            color: llmState === "down" ? root.look.colors.colorOffline
                : llmState === "busy" ? root.look.colors.colorBusy : root.look.colors.colorIdle,
        }
    }
    readonly property string llmGpuText: {
        if (!llm || !llm.gpu) return ""
        const g = llm.gpu, m = llm.memory || {}
        const num = v => v === null || v === undefined ? "–" : v
        return i18n("GPU %1% · %2 GB allocated · RAM %3% used · swap %4 / %5 GB", num(g.util), num(g.alloc_gb),
                    m.free_pct === null || m.free_pct === undefined ? "–" : 100 - m.free_pct,
                    num(m.swap_used_gb), num(m.swap_total_gb))
    }
    readonly property string llmSummary: {
        if (!llmState) return ""
        const down = llmServers.filter(s => !s.up).length
        if (down > 0) return i18np("%1 LLM server down", "%1 LLM servers down", down)
        return i18n("LLMs: GPU %1%", llm.gpu && llm.gpu.util !== null && llm.gpu.util !== undefined ? llm.gpu.util : "–")
    }

    // Runner states in panel order, worst first. Colours come from the Appearance settings and
    // default to the dashboard's own; "glyph" is the square style's symbol, "roundGlyph" the rounded one's.
    readonly property var runnerStates: [
        { key: "offline", label: i18n("Offline"), glyph: "cross", roundGlyph: "cross", color: root.look.colors.colorOffline,
          inPanel: Plasmoid.configuration.showOfflineInPanel },
        { key: "busy", label: i18n("Busy"), glyph: "play", roundGlyph: "play", color: root.look.colors.colorBusy,
          inPanel: Plasmoid.configuration.showBusyInPanel },
        { key: "idle", label: i18n("Idle"), glyph: "check", roundGlyph: "check", color: root.look.colors.colorIdle,
          inPanel: Plasmoid.configuration.showIdleInPanel },
    ]
    readonly property var stateCounts: Logic.countStates(runners)
    readonly property var visibleStates: Logic.visibleStates(runnerStates, stateCounts)
    // Badges (in the panel, the popup and on the desktop) show the states switched on in the
    // settings, optionally including empty ones.
    readonly property var panelStates: Logic.panelStates(runnerStates, stateCounts, Plasmoid.configuration.showZeroInPanel)
    readonly property var sortedRunners: Logic.sortRunners(runners, runnerStates.map(st => st.key))
    readonly property bool badgeMode: root.look.badgeStyle !== "dot"

    // The worst state of any runner, for the status dot.
    readonly property string overallState: visibleStates.length > 0 ? visibleStates[0].key : "unknown"

    readonly property string summary: {
        if (!serverUrl) return i18n("Set the dashboard address in the settings")
        if (!loaded) return i18n("Checking runners…")
        if (runners.length === 0) return i18n("No runners found")
        const offline = stateCounts.offline || 0
        const busy = stateCounts.busy || 0
        if (offline > 0) return i18np("%1 runner offline", "%1 runners offline", offline)
        if (busy > 0) return i18np("%1 runner busy", "%1 runners busy", busy)
        return i18np("%1 runner idle", "All %1 runners idle", runners.length)
    }

    // White or near-black, whichever reads better on the given background colour.
    function contrastText(background) {
        const c = Qt.color(background)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6 ? "#202020" : "white"
    }

    function stateColor(key) {
        const st = runnerStates.find(st => st.key === key)
        return st ? st.color : Kirigami.Theme.disabledTextColor
    }

    function stateLabel(key) {
        const st = runnerStates.find(st => st.key === key)
        return st ? st.label : key
    }

    function jobStatusLabel(status) {
        switch (status) {
        case "ok": return i18n("OK")
        case "running": return i18n("Running")
        case "waiting": return i18n("Not run yet")
        case "failed": return i18n("Failed")
        case "missed": return i18n("Missed")
        case "not loaded": return i18n("Not loaded")
        default: return status || i18n("Unknown")
        }
    }

    function ago(time) {
        return time ? i18n("%1 ago", Logic.formatDuration(serverNow - time)) : "–"
    }

    function refresh() {
        if (!serverUrl || loading) {
            return
        }
        loading = true
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) {
                return
            }
            loading = false
            lastChecked = new Date()
            if (xhr.status !== 200) {
                errorText = xhr.status ? i18n("HTTP error %1", xhr.status) : i18n("Can't reach %1", serverUrl)
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
        const result = Logic.changes(data.runners, snapshot)
        serverNow = data.now
        host = data.host
        runners = data.runners
        snapshot = result.snapshot
        llm = data.llm || null
        const llmResult = Logic.llmChanges(llm, llmSnapshot)
        llmSnapshot = llmResult.snapshot
        jobs = data.jobs || []
        const jobResult = Logic.jobChanges(jobs, jobSnapshot)
        jobSnapshot = jobResult.snapshot
        loaded = true

        if (jobResult.newlyFailing.length > 0 && Plasmoid.configuration.notifyOnJobProblem) {
            const j = jobResult.newlyFailing[0]
            jobNotification.title = jobResult.newlyFailing.length === 1
                ? i18n("Scheduled job %1: %2", j.name, jobStatusLabel(j.status))
                : i18np("%1 scheduled job failing", "%1 scheduled jobs failing", jobResult.newlyFailing.length)
            jobNotification.text = jobResult.newlyFailing.map(j => {
                const line = Logic.lastLogLine(j)
                return j.name + (line ? " · " + line.text : "")
            }).join("\n")
            jobNotification.sendEvent()
        }

        if (llmResult.wentDown.length > 0 && Plasmoid.configuration.notifyOnLlmDown) {
            notification.title = i18np("LLM server down", "%1 LLM servers down", llmResult.wentDown.length)
            notification.text = llmResult.wentDown.map(s => s.name).join("\n")
            notification.sendEvent()
        }

        if (result.wentOffline.length > 0 && Plasmoid.configuration.notifyOnOffline) {
            notification.title = i18np("Runner offline", "%1 runners offline", result.wentOffline.length)
            notification.text = result.wentOffline.map(r => Logic.title(r)).join("\n")
            notification.sendEvent()
        }
        if (result.failedJobs.length > 0 && Plasmoid.configuration.notifyOnFailedJob) {
            const f = result.failedJobs[0]
            notification.title = result.failedJobs.length === 1
                ? i18n("Job %1 failed", f.job.name)
                : i18np("%1 job failed", "%1 jobs failed", result.failedJobs.length)
            notification.text = result.failedJobs.slice(0, 4).map(f => f.job.name + " · " + Logic.title(f.runner)).join("\n")
            notification.sendEvent()
        }
    }

    onServerUrlChanged: {
        loaded = false
        runners = []
        host = null
        snapshot = null
        llm = null
        llmSnapshot = null
        jobs = []
        jobSnapshot = null
        errorText = ""
        loading = false
        refresh()
    }

    Plasmoid.icon: "run-build"

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

    Plasmoid.status: (stateCounts.offline || 0) > 0 || (failingJobCount > 0 && Plasmoid.configuration.showJobsInPanel)
        ? PlasmaCore.Types.NeedsAttentionStatus
        : PlasmaCore.Types.ActiveStatus

    toolTipMainText: i18n("Runner Status")
    toolTipSubText: errorText || [summary, llmSummary, jobsSummary].filter(t => t).join("\n")

    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 12

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refresh()
        },
        PlasmaCore.Action {
            text: i18n("Open Dashboard")
            icon.name: "internet-web-browser"
            enabled: root.serverUrl !== ""
            onTriggered: Qt.openUrlExternally(root.serverUrl)
        }
    ]

    Notification {
        id: notification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "run-build"
    }

    // Its own notification, so a failing job doesn't replace a runner or LLM one sent in the same check.
    Notification {
        id: jobNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "run-build"
    }

    Timer {
        interval: Plasmoid.configuration.pollInterval * 1000
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
        play: { fill: "M 36 25 L 76 50 L 36 75 Z" },
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
        property var badgeState
        property var count
        property real size
        readonly property bool rounded: root.look.badgeStyle === "rounded"

        implicitHeight: size
        implicitWidth: glyphBlock.width + countLabel.implicitWidth + size * (rounded ? 0.7 : 0.5)
        radius: rounded ? height / 2 : 2
        color: root.look.colors.colorCountBackground
        border.width: rounded ? 1.5 : 1
        border.color: badgeState.color

        Rectangle {
            id: glyphBlock
            width: parent.size
            height: parent.size
            radius: parent.rounded ? width / 2 : 2
            color: badgeState.color

            Glyph {
                anchors.centerIn: parent
                width: parent.width * 0.7
                height: width
                kind: parent.parent.rounded ? badgeState.roundGlyph : badgeState.glyph
                color: root.contrastText(badgeState.color)
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
        // Badges after the runner badges ({glyph, roundGlyph, color, count}): root.extraBadges.
        property var extraBadges: []
        readonly property int itemCount: badgeStates.length + (showTotal ? 1 : 0) + (showLogo ? 1 : 0) + extraBadges.length

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
                badgeState: modelData
                count: root.stateCounts[modelData.key] || 0
                size: bar.badgeSize
            }
        }

        PlasmaComponents.Label {
            textFormat: Text.PlainText
            visible: bar.showTotal
            text: i18n("(of %1)", root.runners.length)
            font.pixelSize: bar.badgeSize * 0.6
        }

        Repeater {
            model: bar.extraBadges
            StatusBadge {
                required property var modelData
                badgeState: modelData
                count: modelData.count
                size: bar.badgeSize
            }
        }
    }

    compactRepresentation: MouseArea {
        id: compact

        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        readonly property real badgeSize: Math.min(Kirigami.Units.iconSizes.smallMedium, vertical ? width : height)
        readonly property bool showTotal: Plasmoid.configuration.showTotalInPanel && root.runners.length > 0
        readonly property bool showBadges: root.badgeMode
            && ((root.runners.length > 0 && (root.panelStates.length > 0 || showTotal)) || root.extraBadges.length > 0)

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
            badgeStates: root.runners.length > 0 ? root.panelStates : []
            showTotal: compact.showTotal
            extraBadges: root.extraBadges
            showLogo: root.look.showLogo
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
                source: root.look.showLogo && root.customLogo || Plasmoid.icon
                active: compact.containsMouse
            }

            Rectangle {
                width: Math.max(Kirigami.Units.smallSpacing * 2, parent.width * 0.35)
                height: width
                radius: width / 2
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                color: root.errorText ? root.stateColor("unknown") : root.stateColor(root.overallState)
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
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
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
                    color: root.errorText ? root.stateColor("unknown") : root.stateColor(root.overallState)
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
                    text: i18n("Open Dashboard")
                    enabled: root.serverUrl !== ""
                    onClicked: Qt.openUrlExternally(root.serverUrl)
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }

                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Refresh")
                    enabled: !root.loading && root.serverUrl !== ""
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
                visible: root.badgeMode && (root.runners.length > 0 || root.extraBadges.length > 0)
                badgeSize: Kirigami.Units.iconSizes.small * 1.25
                badgeStates: root.runners.length > 0 ? root.panelStates : []
                showTotal: Plasmoid.configuration.showTotalInPanel && root.runners.length > 0
                extraBadges: root.extraBadges
            }

            // The machine the runners live on.
            PlasmaComponents.Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
                visible: root.host !== null
                opacity: 0.7
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
                text: root.host
                    ? i18n("%1 · load %2 · up %3 · %4 of %5 GB free", root.host.hostname, (root.host.load || []).join(" / "),
                        Logic.formatDuration(root.host.uptime), root.host.disk_free_gb, root.host.disk_total_gb)
                    : ""
            }

            PlasmaComponents.Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.smallSpacing
                opacity: 0.7
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
                color: root.errorText ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
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

                // ---- Local LLMs, when the dashboard reports them ----
                GroupHeader {
                    id: llmHeader
                    visible: root.llm !== null
                    groupKey: "llm"
                    text: i18n("Local LLMs")
                }

                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    visible: root.llmGpuText !== "" && !llmHeader.collapsed
                    wrapMode: Text.WordWrap
                    font: Kirigami.Theme.smallFont
                    // Nearly full swap is the usual reason generation slows down.
                    color: (Logic.swapPercent(root.llm ? root.llm.memory : null) || 0) >= 80
                        ? root.stateColor("busy") : Kirigami.Theme.textColor
                    text: root.llmGpuText
                }

                Repeater {
                    model: llmHeader.collapsed ? [] : root.llmServers

                    PlasmaComponents.ItemDelegate {
                        id: llmItem
                        required property var modelData
                        readonly property color stateColor: root.stateColor(modelData.up ? "idle" : "offline")

                        Layout.fillWidth: true
                        onClicked: Qt.openUrlExternally(root.serverUrl)

                        contentItem: ColumnLayout {
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Rectangle {
                                    Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                                    Layout.preferredHeight: width
                                    radius: width / 2
                                    color: llmItem.stateColor
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: llmItem.modelData.kind === "mlx" ? i18n("MLX · %1", llmItem.modelData.name) : llmItem.modelData.name
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    text: llmItem.modelData.up ? i18n("Up") : i18n("Down")
                                    color: llmItem.stateColor
                                }
                            }

                            // Ollama: the loaded models. MLX: memory and prompt cache.
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: {
                                    const s = llmItem.modelData
                                    if (!s.up) return s.error || i18n("Not responding")
                                    if (s.kind === "ollama") {
                                        return s.models.length === 0 ? i18n("No model loaded")
                                            : s.models.map(m => m.expires
                                                ? i18n("%1 · %2 GB · unloads in %3", m.name, m.size_gb,
                                                       Logic.formatDuration(Date.parse(m.expires) / 1000 - root.serverNow))
                                                : i18n("%1 · %2 GB", m.name, m.size_gb)).join(", ")
                                    }
                                    return [
                                        s.footprintGb !== null && s.footprintGb !== undefined ? i18n("%1 GB in memory", s.footprintGb) : "",
                                        s.promptCache ? i18n("prompt cache %1 GB", s.promptCache.gb) : "",
                                    ].filter(t => t).join(" · ")
                                }
                            }

                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                text: {
                                    const s = llmItem.modelData
                                    return [
                                        s.kind === "ollama" ? (s.version ? "v" + s.version : "") : s.label,
                                        s.kind === "mlx" && s.up && s.uptime ? i18n("up %1", Logic.formatDuration(s.uptime)) : "",
                                        s.lastRequest ? i18n("last request %1", root.ago(s.lastRequest)) : i18n("no requests yet"),
                                    ].filter(t => t).join(" · ")
                                }
                            }
                        }
                    }
                }

                // ---- Scheduled jobs (e.g. a nightly backup), when the dashboard reports any ----
                GroupHeader {
                    id: jobsHeader
                    visible: root.jobs.length > 0
                    groupKey: "jobs"
                    text: i18n("Scheduled jobs")
                }

                Repeater {
                    model: jobsHeader.collapsed ? [] : root.sortedJobs

                    PlasmaComponents.ItemDelegate {
                        id: jobItem
                        required property var modelData
                        readonly property string jobState: Logic.jobState(modelData)
                        readonly property bool failing: Logic.jobFailing(modelData)
                        readonly property var lastLine: Logic.lastLogLine(modelData)

                        Layout.fillWidth: true
                        onClicked: Qt.openUrlExternally(root.serverUrl)

                        contentItem: ColumnLayout {
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Rectangle {
                                    Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                                    Layout.preferredHeight: width
                                    radius: width / 2
                                    color: root.stateColor(jobItem.jobState)
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: jobItem.modelData.name || ""
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    text: jobItem.modelData.exit_code
                                        ? i18n("%1 (exit %2)", root.jobStatusLabel(jobItem.modelData.status), jobItem.modelData.exit_code)
                                        : root.jobStatusLabel(jobItem.modelData.status)
                                    color: root.stateColor(jobItem.jobState)
                                }
                            }

                            // Schedule, last and next run.
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: {
                                    const j = jobItem.modelData
                                    return [
                                        j.schedule || "",
                                        j.last_run ? i18n("last run %1", root.ago(j.last_run)) : i18n("not run yet"),
                                        j.next_run && j.next_run > root.serverNow
                                            ? i18n("next in %1", Logic.formatDuration(j.next_run - root.serverNow)) : "",
                                    ].filter(t => t).join(" · ")
                                }
                            }

                            // The newest log line, e.g. "saved storyforge-….tar.gz (8.0K)".
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                visible: !!jobItem.lastLine || !!jobItem.modelData.error
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                color: jobItem.failing ? root.stateColor("offline") : Kirigami.Theme.textColor
                                opacity: jobItem.failing ? 1 : 0.7
                                text: jobItem.modelData.error
                                    || (jobItem.lastLine ? jobItem.lastLine.text : "")
                            }
                        }
                    }
                }

                // Only needed to tell the runners apart from the sections above them.
                GroupHeader {
                    id: runnersHeader
                    visible: (root.llm !== null || root.jobs.length > 0) && root.runners.length > 0
                    groupKey: "runners"
                    text: i18n("Runners")
                }

                Repeater {
                    id: runnerRepeater
                    model: runnersHeader.visible && runnersHeader.collapsed ? [] : root.sortedRunners

                    PlasmaComponents.ItemDelegate {
                        id: runnerItem
                        required property var modelData
                        readonly property string runnerState: Logic.runnerState(modelData)
                        readonly property var job: modelData.job
                        readonly property var last: Logic.lastJob(modelData)
                        readonly property int problemCount: (modelData.problems || []).length

                        Layout.fillWidth: true
                        onClicked: if (Logic.actionsUrl(modelData)) Qt.openUrlExternally(Logic.actionsUrl(modelData))
                        PlasmaComponents.ToolTip.text: Logic.actionsUrl(modelData)
                        PlasmaComponents.ToolTip.visible: hovered && PlasmaComponents.ToolTip.text !== ""

                        contentItem: ColumnLayout {
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Rectangle {
                                    Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                                    Layout.preferredHeight: width
                                    radius: width / 2
                                    color: root.stateColor(runnerItem.runnerState)
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: Logic.title(runnerItem.modelData)
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    text: root.stateLabel(runnerItem.runnerState)
                                    color: root.stateColor(runnerItem.runnerState)
                                }
                            }

                            // The running job.
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                visible: !!runnerItem.job
                                elide: Text.ElideRight
                                text: runnerItem.job
                                    ? i18n("%1 in %2 · running %3", runnerItem.job.job || i18n("job"), runnerItem.job.workflow || i18n("workflow"),
                                        Logic.formatDuration(root.serverNow - runnerItem.job.started))
                                    : ""
                            }

                            // The last finished job.
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                visible: !!runnerItem.last
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                color: Logic.jobFailed(runnerItem.last) ? root.stateColor("offline") : Kirigami.Theme.textColor
                                opacity: Logic.jobFailed(runnerItem.last) ? 1 : 0.7
                                text: runnerItem.last
                                    ? i18n("Last: %1 %2 · %3", runnerItem.last.name, runnerItem.last.result, root.ago(runnerItem.last.finished))
                                    : ""
                            }

                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                text: [
                                    runnerItem.modelData.name,
                                    runnerItem.modelData.version ? "v" + runnerItem.modelData.version : "",
                                    runnerItem.runnerState !== "offline" ? i18n("up %1", Logic.formatDuration(runnerItem.modelData.uptime)) : "",
                                    runnerItem.problemCount > 0 ? i18np("%1 recent warning", "%1 recent warnings", runnerItem.problemCount) : "",
                                ].filter(s => s).join(" · ")
                            }
                        }
                    }
                }

                PlasmaExtras.PlaceholderMessage {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.gridUnit * 2
                    visible: root.runners.length === 0
                    iconName: root.errorText ? "network-disconnect" : root.loading ? "view-refresh" : "run-build"
                    text: root.errorText ? root.errorText : root.summary
                }
            }
        }
    }
}
