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

    readonly property string scriptPath: Qt.resolvedUrl("../code/sentry.py").toString().replace("file://", "")
    readonly property string serverUrl: Plasmoid.configuration.serverUrl.trim().replace(/\/+$/, "")
    readonly property string organization: Plasmoid.configuration.organization.trim()
    // sentry.py's filter options from the settings; changing them starts over, as their counts differ.
    readonly property string filterOptions: {
        const environment = Plasmoid.configuration.environment.trim()
        return (Plasmoid.configuration.levelErrorsOnly ? " --errors-only" : "")
            + (Plasmoid.configuration.categoryErrorsOnly ? " --category-errors" : "")
            + (environment !== "" ? " --environment " + Logic.shellQuote(environment) : "")
    }
    // The regressed count only adds to the counts, so switching it does not start over.
    readonly property string fetchOptions: filterOptions + (Plasmoid.configuration.showRegressedInPanel ? " --regressed" : "")
    readonly property bool configured: serverUrl !== "" && organization !== ""
    readonly property string issuesPageUrl: Logic.issuesPageUrl(serverUrl, organization)

    // Unresolved issues as sentry.py prints them (most recently seen first), the counts it read
    // from Sentry, and whether there were more unresolved issues than it listed.
    property var issues: []
    property var counts: ({})
    property bool truncated: false
    // Ids of issues already seen, to notify only about new ones; null until the first check.
    property var seenIssueIds: null
    // Each listed issue's substatus at the last check, to notice regressions; null until the first check.
    property var lastSubstatus: null
    // Ids of issues with a resolve/archive in progress.
    property var busyIds: ({})
    property bool loaded: false
    property date lastChecked
    property string errorText: ""
    property string actionError: ""

    // Issue states in panel order, worst first. Colours come from the Appearance settings.
    // "glyph" (a glyphPaths key) is used by the square style, "roundGlyph" by the rounded one.
    readonly property var issueStates: [
        { key: "new", label: i18n("New"), glyph: "plus", roundGlyph: "plus", color: root.look.colors.colorNew,
          inPanel: Plasmoid.configuration.showNewInPanel },
        { key: "open", label: i18n("Open"), glyph: "exclamation", roundGlyph: "exclamation", color: root.look.colors.colorOpen,
          inPanel: Plasmoid.configuration.showOpenInPanel },
        { key: "archived", label: i18n("Archived"), glyph: "muted", roundGlyph: "muted", color: root.look.colors.colorArchived,
          inPanel: Plasmoid.configuration.showArchivedInPanel },
        { key: "resolved", label: i18n("Resolved"), glyph: "check", roundGlyph: "check", color: root.look.colors.colorResolved,
          inPanel: Plasmoid.configuration.showResolvedInPanel },
        { key: "regressed", label: i18n("Regressed"), glyph: "restart", roundGlyph: "restart", color: root.look.colors.colorRegressed,
          inPanel: Plasmoid.configuration.showRegressedInPanel },
    ]

    // An unresolved issue counts as new when it was first seen within the last 24 hours.
    function isNew(issue) {
        return Logic.isNew(issue, Date.now())
    }

    readonly property var stateCounts: Logic.countStates(counts)
    readonly property int totalIssues: stateCounts.new + stateCounts.open + stateCounts.archived + stateCounts.resolved
    readonly property var visibleStates: Logic.visibleStates(issueStates, stateCounts)
    // Badges (in the panel, the popup and on the desktop) show the states switched on in the
    // settings, optionally including empty ones.
    readonly property var panelStates: Logic.panelStates(issueStates, stateCounts, Plasmoid.configuration.showZeroInPanel)
    // Unresolved issues per project, most recently active project first.
    readonly property var projectGroups: Logic.groupByProject(issues)

    function stateOf(key) {
        return issueStates.find(st => st.key === key)
    }

    // White or near-black, whichever reads better on the given background colour.
    function contrastText(background) {
        const c = Qt.color(background)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6 ? "#202020" : "white"
    }

    function refresh() {
        if (!configured) {
            return
        }
        fetcher.connectSource("python3 -I " + Logic.shellQuote(scriptPath) + " fetch " + Logic.shellQuote(serverUrl)
            + " " + Logic.shellQuote(organization) + " " + Plasmoid.configuration.maxPages
            + fetchOptions)
    }

    function runAction(issue, action) {
        const busy = Object.assign({}, busyIds)
        busy[issue.id] = true
        busyIds = busy
        actionError = ""
        actions.connectSource("python3 -I " + Logic.shellQuote(scriptPath) + " " + action + " " + Logic.shellQuote(serverUrl)
            + " " + Logic.shellQuote(organization) + " " + Logic.shellQuote(issue.id))
    }

    function issueUrl(issue) {
        return Logic.issueUrl(serverUrl, organization, issue)
    }

    // The colour and label of a row tag from Logic.issueTags.
    function tagColor(tag) {
        return tag === "unhandled" ? root.look.colors.colorOpen
            : tag === "regressed" ? root.look.colors.colorRegressed : root.look.colors.colorNew
    }

    function tagLabel(tag) {
        switch (tag) {
        case "fatal": return i18n("fatal")
        case "regressed": return i18n("regressed")
        case "escalating": return i18n("escalating")
        default: return i18n("unhandled")
        }
    }

    function issueTitle(issue) {
        return issue.title || i18n("(no message)")
    }

    function relativeTime(iso) {
        const age = Logic.age(iso, Date.now())
        switch (age.unit) {
        case "minute": return i18np("%1 minute ago", "%1 minutes ago", age.count)
        case "hour": return i18np("%1 hour ago", "%1 hours ago", age.count)
        default: return i18np("%1 day ago", "%1 days ago", age.count)
        }
    }

    function apply(data) {
        issues = data.issues
        counts = data.counts
        truncated = data.truncated
        loaded = true
        notifyAboutNew()
    }

    function notifyAboutNew() {
        const regressed = Logic.regressedIssues(issues, seenIssueIds, lastSubstatus)
        lastSubstatus = Logic.substatusById(issues, lastSubstatus)
        const result = Logic.freshIssues(issues, seenIssueIds)
        const fresh = result.fresh
        seenIssueIds = result.seen

        if (regressed.length > 0 && Plasmoid.configuration.notifyOnRegression) {
            if (regressed.length === 1) {
                regressedNotification.title = i18n("Sentry: issue regressed in %1", regressed[0].project)
                regressedNotification.text = issueTitle(regressed[0])
            } else {
                regressedNotification.title = i18np("Sentry: %1 issue regressed", "Sentry: %1 issues regressed", regressed.length)
                regressedNotification.text = regressed.slice(0, 4).map(i => i.project + " – " + issueTitle(i)).join("\n")
            }
            regressedNotification.sendEvent()
        }

        if (fresh.length === 0 || !Plasmoid.configuration.notifyOnNew) {
            return
        }
        if (fresh.length === 1) {
            newIssueNotification.title = i18n("Sentry: new issue in %1", fresh[0].project)
            newIssueNotification.text = issueTitle(fresh[0])
        } else {
            newIssueNotification.title = i18np("Sentry: %1 new issue", "Sentry: %1 new issues", fresh.length)
            newIssueNotification.text = fresh.slice(0, 4).map(i => i.project + " – " + issueTitle(i)).join("\n")
        }
        newIssueNotification.sendEvent()
    }

    onServerUrlChanged: reset()
    onOrganizationChanged: reset()
    onFilterOptionsChanged: reset()
    onFetchOptionsChanged: refresh()

    function reset() {
        loaded = false
        issues = []
        counts = ({})
        truncated = false
        seenIssueIds = null
        lastSubstatus = null
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
                root.errorText = i18n("Could not read Sentry response: %1", e.message)
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
                root.actionError = data["stderr"].trim() || i18n("The change failed with code %1", data["exit code"])
            }
            root.refresh()
        }
    }

    Notification {
        id: newIssueNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "script-error"
    }

    Notification {
        id: regressedNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "script-error"
    }

    Timer {
        interval: Plasmoid.configuration.pollInterval * 60 * 1000
        running: root.configured
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

    Plasmoid.status: stateCounts.new > 0 ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus

    toolTipMainText: i18n("Sentry")
    toolTipSubText: {
        if (!configured) return i18n("No organization configured")
        if (errorText) return errorText
        if (!loaded) return i18n("Loading…")
        if (totalIssues === 0) return i18n("No issues")
        return visibleStates.map(st => i18n("%1 %2", stateCounts[st.key], st.label.toLowerCase())).join(" · ")
            + (truncated ? "\n" + i18n("The list shows the most recently seen unresolved issues.") : "")
    }

    switchWidth: Kirigami.Units.gridUnit * 14
    switchHeight: Kirigami.Units.gridUnit * 14

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            enabled: root.configured
            onTriggered: root.refresh()
        },
        PlasmaCore.Action {
            text: i18n("Open Sentry")
            icon.name: "internet-web-browser"
            enabled: root.configured
            onTriggered: Qt.openUrlExternally(root.issuesPageUrl)
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
        property var issueState
        property int count
        property real size
        readonly property bool rounded: root.look.badgeStyle === "rounded"

        implicitHeight: size
        implicitWidth: glyphBlock.width + countLabel.implicitWidth + size * (rounded ? 0.7 : 0.5)
        radius: rounded ? height / 2 : 2
        color: root.look.colors.colorCountBackground
        border.width: rounded ? 1.5 : 1
        border.color: issueState.color

        Rectangle {
            id: glyphBlock
            width: parent.size
            height: parent.size
            radius: parent.rounded ? width / 2 : 2
            color: issueState.color

            Glyph {
                anchors.centerIn: parent
                width: parent.width * 0.7
                height: width
                kind: parent.parent.rounded ? issueState.roundGlyph : issueState.glyph
                color: root.contrastText(issueState.color)
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
                issueState: modelData
                count: root.stateCounts[modelData.key] || 0
                size: bar.badgeSize
            }
        }

        PlasmaComponents.Label {
            textFormat: Text.PlainText
            visible: bar.showTotal
            text: i18n("(of %1)", root.totalIssues)
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

    // One open issue in the popup: state dot, title, details, and resolve/archive buttons.
    component IssueRow: PlasmaComponents.ItemDelegate {
        id: row
        property var issue
        readonly property bool busy: root.busyIds[issue.id] === true
        readonly property bool fresh: root.isNew(issue)

        Layout.fillWidth: true
        onClicked: Qt.openUrlExternally(root.issueUrl(issue))

        contentItem: RowLayout {
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
                Layout.preferredHeight: width
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: Kirigami.Units.smallSpacing
                radius: width / 2
                color: root.stateOf(Logic.severityState(row.issue)).color
            }

            ColumnLayout {
                Layout.fillWidth: true
                // Only the width left beside the buttons, so long lines elide instead of running under them.
                Layout.preferredWidth: 1
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents.Label {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: root.issueTitle(row.issue)
                        font.bold: row.fresh
                        elide: Text.ElideRight
                    }
                    Repeater {
                        model: Logic.issueTags(row.issue)
                        Rectangle {
                            required property string modelData
                            readonly property color tagColor: root.tagColor(modelData)
                            implicitWidth: tagLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                            implicitHeight: tagLabel.implicitHeight
                            radius: 2
                            color: tagColor
                            PlasmaComponents.Label {
                                id: tagLabel
                                anchors.centerIn: parent
                                text: root.tagLabel(parent.modelData)
                                font: Kirigami.Theme.smallFont
                                color: root.contrastText(parent.tagColor)
                            }
                        }
                    }
                }
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: [row.issue.shortId, row.issue.culprit,
                           i18np("%1 event in 90 days", "%1 events in 90 days", parseInt(row.issue.count) || 0),
                           Logic.events24h(row.issue) !== null ? i18n("%1 in 24h", Logic.events24h(row.issue)) : "",
                           row.issue.userCount ? i18np("%1 user", "%1 users", row.issue.userCount) : "",
                           row.issue.assignee ? "→ " + row.issue.assignee : "",
                           i18n("last seen %1", root.relativeTime(row.issue.lastSeen))].filter(t => t).join(" · ")
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    elide: Text.ElideRight
                }
            }

            PlasmaComponents.BusyIndicator {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                visible: row.busy
                running: visible
            }

            PlasmaComponents.ToolButton {
                visible: !row.busy
                icon.name: "checkmark"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Resolve")
                onClicked: root.runAction(row.issue, "resolve")
                PlasmaComponents.ToolTip.text: text
                PlasmaComponents.ToolTip.visible: hovered
            }
            PlasmaComponents.ToolButton {
                visible: !row.busy
                icon.name: "archive-insert"
                display: PlasmaComponents.AbstractButton.IconOnly
                text: i18n("Archive")
                onClicked: root.runAction(row.issue, "archive")
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
                    text: root.configured ? root.organization + " · " + root.serverUrl.replace(/^https?:\/\//, "") : i18n("Sentry")
                    elide: Text.ElideRight
                }

                PlasmaComponents.ToolButton {
                    icon.name: "internet-web-browser"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Open Sentry")
                    enabled: root.configured
                    onClicked: Qt.openUrlExternally(root.issuesPageUrl)
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }

                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Refresh")
                    enabled: root.configured
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
            visible: !root.configured
            iconName: "configure"
            text: i18n("No Sentry organization configured")
            helpfulAction: QQC2.Action {
                text: i18n("Configure…")
                icon.name: "configure"
                onTriggered: Plasmoid.internalAction("configure").trigger()
            }
        }

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: root.configured && root.errorText !== "" && !root.loaded
            iconName: "dialog-error"
            text: i18n("Could not reach Sentry")
            explanation: root.errorText
        }

        PlasmaExtras.PlaceholderMessage {
            anchors.centerIn: parent
            width: parent.width - Kirigami.Units.gridUnit * 2
            visible: root.loaded && root.issues.length === 0
            iconName: "checkmark"
            text: i18n("No open issues")
        }

        PlasmaComponents.ScrollView {
            id: scroll
            anchors.fill: parent
            // Long titles are elided instead of making the list scroll sideways.
            contentWidth: availableWidth
            // Never scroll sideways. An as-needed horizontal bar would also toggle with the vertical one,
            // which changes availableWidth: a binding loop on its "visible".
            PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff
            visible: root.loaded && root.issues.length > 0

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
                    model: root.projectGroups

                    ColumnLayout {
                        id: group
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 0

                        GroupHeader {
                            id: projectHeader
                            groupKey: "project:" + group.modelData.name
                            text: i18n("%1 (%2 unresolved)", group.modelData.name, group.modelData.issues.length)
                        }
                        Repeater {
                            model: projectHeader.collapsed ? [] : group.modelData.issues
                            IssueRow {
                                required property var modelData
                                issue: modelData
                            }
                        }
                    }
                }
            }
        }
    }
}
