import QtQuick
import QtQuick.Layouts
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

    readonly property string releaseScriptPath: Qt.resolvedUrl("../code/release.sh").toString().replace("file://", "")
    readonly property string scriptPath: Qt.resolvedUrl("../code/fetch.sh").toString().replace("file://", "")
    // Which gh account to show; empty means gh's active account.
    readonly property string account: Plasmoid.configuration.account.trim()

    property string login: ""
    property var notifications: []
    property var reviews: []
    property var pullRequests: []
    property var repos: []
    // CI category of every PR and repo at the last check, to spot changes; null before the first check.
    property var ciSnapshot: null
    // Totals from GitHub, not capped at the 20 items the lists show.
    property int prCount: 0
    property int reviewCount: 0
    property var seenNotificationIds: null
    property date lastChecked
    property string errorText: ""
    property bool loading: false

    readonly property var unreadNotifications: notifications.filter(n => n.unread)
    // Only the newest Logic.notificationLimit unread notifications are fetched, so a full page may be more.
    readonly property bool moreNotifications: unreadNotifications.length >= Logic.notificationLimit
    readonly property bool countTeamReviews: Plasmoid.configuration.countTeamReviews

    // Repos pushed recently enough for their main branch CI to say anything about now.
    readonly property var shownRepos: Logic.recentRepos(repos, Plasmoid.configuration.ciRepoDays, Date.now())
    // Your PRs with changes requested or merge conflicts.
    readonly property var prActions: Logic.prCounts(pullRequests)

    // CI state of your open PRs plus the main branch of your recently pushed repos.
    readonly property var ciCounts: Logic.ciCounts(pullRequests, shownRepos)
    readonly property int ciFailing: ciCounts.failing
    readonly property int ciRunning: ciCounts.running
    readonly property int ciPassing: ciCounts.passing

    // Badge and dot colours from the Appearance settings; they default to GitHub's own colours.
    readonly property color reviewsColor: root.look.colors.colorReviews
    readonly property color notificationsColor: root.look.colors.colorNotifications
    readonly property color pullRequestsColor: root.look.colors.colorPullRequests
    readonly property color ciFailingColor: root.look.colors.colorCiFailing
    readonly property color ciRunningColor: root.look.colors.colorCiRunning
    readonly property color ciPassingColor: root.look.colors.colorCiPassing

    // White or near-black, whichever reads better on the given background colour.
    function contrastText(background) {
        const c = Qt.color(background)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6 ? "#202020" : "white"
    }


    // The badges shown in the panel and the popup, PRTG-status-bar style; zero counts are hidden.
    readonly property var countBadges: [
        { label: i18n("review requests"), icon: "view-visible-symbolic", color: reviewsColor, count: reviewCount },
        { label: i18n("unread notifications"), icon: "notifications-symbolic", color: notificationsColor, count: unreadNotifications.length,
          display: Logic.countText(unreadNotifications.length, Logic.notificationLimit) },
        { label: i18n("open pull requests"), icon: "vcs-merge-request-symbolic", color: pullRequestsColor, count: prCount },
        { label: i18n("pull requests need your action"), icon: "dialog-warning-symbolic", color: ciFailingColor,
          count: Plasmoid.configuration.showActionBadge ? prActions.needsAction : 0 },
        { label: i18n("CI failing"), icon: "dialog-cancel-symbolic", color: ciFailingColor, count: ciFailing },
        { label: i18n("CI running"), icon: "chronometer-symbolic", color: ciRunningColor, count: ciRunning },
        { label: i18n("CI passing"), icon: "checkmark-symbolic", color: ciPassingColor, count: ciPassing },
    ]
    readonly property var visibleBadges: countBadges.filter(b => b.count > 0)

    function ciColor(state) {
        switch (Logic.ciCategory(state)) {
        case "passing": return ciPassingColor
        case "failing": return ciFailingColor
        case "running": return ciRunningColor
        default: return Kirigami.Theme.disabledTextColor
        }
    }

    function ciLabel(state) {
        switch (Logic.ciCategory(state)) {
        case "passing": return i18n("Checks passed")
        case "failing": return i18n("Checks failed")
        case "running": return i18n("Checks running")
        default: return i18n("No checks")
        }
    }

    function notificationUrl(n) {
        return Logic.notificationUrl(n)
    }

    // A release notification only knows its API URL; the release page is looked up when it is clicked.
    // Falls back to the repo's releases list (fallbackUrl) if the lookup fails.
    function openRelease(apiUrl, fallbackUrl) {
        const cmd = "sh " + Logic.shellQuote(releaseScriptPath) + " " + Logic.shellQuote(account) + " " + Logic.shellQuote(apiUrl)
        pendingReleases[cmd] = fallbackUrl
        releaseLookup.connectSource(cmd)
    }
    property var pendingReleases: ({})

    // The CI line of a PR or repo row: the failing checks' names, progress while running, else the state.
    function ciText(item) {
        const summary = Logic.checkSummary(item, 3)
        if (summary && summary.kind === "failed") {
            const names = summary.names.join(", ")
            return summary.more > 0 ? i18n("Failed: %1 +%2", names, summary.more) : i18n("Failed: %1", names)
        }
        if (summary && summary.kind === "running") {
            return i18np("%1/%2 done", "%1/%2 done", summary.done, summary.total)
        }
        return ciLabel(item.ci)
    }

    // Review and merge state of one of your PRs, e.g. "Changes requested · conflicts"; "" for nothing to say.
    function prStatusText(pr) {
        const words = {
            changesRequested: i18n("changes requested"),
            approved: i18n("approved"),
            reviewRequired: i18n("review required"),
            conflicts: i18n("conflicts"),
            behind: i18n("behind base"),
            unstable: i18n("checks unstable"),
            ready: i18n("ready")
        }
        const text = Logic.prStatus(pr).map(key => words[key]).join(" · ")
        return text.charAt(0).toUpperCase() + text.slice(1)
    }

    function relativeTime(iso) {
        const age = Logic.age(iso, Date.now())
        switch (age.unit) {
        case "minute": return i18np("%1 minute ago", "%1 minutes ago", age.count)
        case "hour": return i18np("%1 hour ago", "%1 hours ago", age.count)
        default: return i18np("%1 day ago", "%1 days ago", age.count)
        }
    }

    property string currentSource: ""

    function refresh(markRead) {
        loading = true
        // Only the newest command's result is applied; one for an earlier account or setting is ignored.
        currentSource = "sh " + Logic.shellQuote(scriptPath) + " " + Logic.shellQuote(account) + (markRead ? " mark-read" : " -") + (countTeamReviews ? "" : " direct-only")
        executable.exec(currentSource)
    }

    onCountTeamReviewsChanged: refresh(false)

    onAccountChanged: {
        login = ""
        notifications = []
        reviews = []
        pullRequests = []
        repos = []
        ciSnapshot = null
        prCount = 0
        reviewCount = 0
        seenNotificationIds = null
        errorText = ""
        refresh(false)
    }

    function apply(data) {
        const parsed = Logic.parse(data)
        login = parsed.login
        notifications = parsed.notifications
        reviews = parsed.reviews
        reviewCount = parsed.reviewCount
        prCount = parsed.prCount
        pullRequests = parsed.pullRequests
        repos = parsed.repos
        notifyAboutNew()
        notifyAboutCi()
    }

    function notifyAboutCi() {
        const changes = Logic.ciChanges(ciSnapshot, pullRequests, shownRepos)
        ciSnapshot = changes.snapshot
        const events = changes.events
        if (events.length === 0 || !Plasmoid.configuration.notifyOnCi) {
            return
        }
        const describe = e => (e.kind === "failing" ? i18n("CI failing: %1", e.title) : i18n("CI fixed: %1", e.title))
        if (events.length === 1) {
            ciNotification.title = describe(events[0])
            ciNotification.text = events[0].subtitle + " · @" + login
        } else {
            ciNotification.title = i18np("%1 CI change", "%1 CI changes", events.length)
            ciNotification.text = events.map(describe).slice(0, 3).concat(["@" + login]).join("\n")
        }
        ciNotification.sendEvent()
    }

    function notifyAboutNew() {
        const result = Logic.freshNotifications(notifications, seenNotificationIds)
        const fresh = result.fresh
        seenNotificationIds = result.seen

        if (fresh.length === 0 || !Plasmoid.configuration.notifyOnNew) {
            return
        }
        if (fresh.length === 1) {
            newNotification.title = fresh[0].subject.title
            newNotification.text = fresh[0].repository.full_name + " · @" + login
        } else {
            newNotification.title = i18np("%1 new GitHub notification", "%1 new GitHub notifications", fresh.length)
            newNotification.text = fresh.map(n => n.subject.title).slice(0, 3).concat(["@" + login]).join("\n")
        }
        newNotification.sendEvent()
    }

    P5Support.DataSource {
        id: releaseLookup
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            const fallback = root.pendingReleases[sourceName]
            delete root.pendingReleases[sourceName]
            const page = (data["stdout"] || "").trim()
            Qt.openUrlExternally(data["exit code"] === 0 && page.startsWith("https://github.com/") ? page : fallback)
        }
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        function exec(cmd) {
            connectSource(cmd)
        }

        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            if (sourceName !== root.currentSource) {
                return
            }
            root.loading = false
            root.lastChecked = new Date()
            if (data["exit code"] !== 0) {
                const stderr = data["stderr"].trim()
                root.errorText = stderr || i18n("gh exited with code %1", data["exit code"])
                return
            }
            try {
                root.apply(JSON.parse(data["stdout"]))
                root.errorText = ""
            } catch (e) {
                root.errorText = i18n("Could not read gh output: %1", e.message)
            }
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

    // The appearance in use: this widget's own settings, or the shared look that every
    // madebypless widget can follow (see SharedLook.qml and look.js).
    SharedLook {
        id: sharedLook
    }
    readonly property var look: Look.resolve(Plasmoid.configuration,
                                             Plasmoid.configuration.useSharedLook ? sharedLook.values : null,
                                             Logic.colorRoles)

    Plasmoid.status: ciFailing > 0 || reviewCount > 0
        ? PlasmaCore.Types.NeedsAttentionStatus
        : PlasmaCore.Types.ActiveStatus

    toolTipMainText: login ? i18n("GitHub: %1", login) : i18n("GitHub Account")
    // What needs your attention, e.g. "2 reviews · 5 unread · 1 CI failing · 1 PR has changes requested".
    readonly property var attentionParts: [
        reviewCount > 0 ? i18np("%1 review", "%1 reviews", reviewCount) : "",
        unreadNotifications.length > 0
            ? (moreNotifications ? i18n("%1+ unread", Logic.notificationLimit)
                                 : i18np("%1 unread", "%1 unread", unreadNotifications.length)) : "",
        ciFailing > 0 ? i18np("%1 CI failing", "%1 CI failing", ciFailing) : "",
        prActions.changesRequested > 0
            ? i18np("%1 PR has changes requested", "%1 PRs have changes requested", prActions.changesRequested) : "",
        prActions.conflicts > 0 ? i18np("%1 PR has conflicts", "%1 PRs have conflicts", prActions.conflicts) : "",
    ].filter(part => part !== "")

    toolTipSubText: errorText
        || (login && visibleBadges.length === 0 ? i18n("Nothing needs your attention") : "")
        || (attentionParts.length > 0 ? attentionParts.join(" · ") : "")
        || visibleBadges.map(b => i18n("%1 %2", b.display || b.count, b.label)).join(" · ")

    switchWidth: Kirigami.Units.gridUnit * 14
    switchHeight: Kirigami.Units.gridUnit * 14

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refresh(false)
        },
        PlasmaCore.Action {
            text: i18n("Mark All Notifications Read")
            icon.name: "mail-mark-read"
            enabled: root.unreadNotifications.length > 0
            onTriggered: root.refresh(true)
        },
        PlasmaCore.Action {
            text: i18n("Open GitHub Notifications")
            icon.name: "internet-web-browser"
            onTriggered: Qt.openUrlExternally("https://github.com/notifications")
        }
    ]

    Notification {
        id: ciNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "vcs-branch"
    }

    Notification {
        id: newNotification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "vcs-branch"
    }

    Timer {
        interval: Plasmoid.configuration.pollInterval * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh(false)
    }

    // A PRTG-style count badge: an icon on a block of the badge's colour, then the count.
    component CountBadge: Rectangle {
        property var badge
        property real size
        readonly property bool rounded: root.look.badgeStyle === "rounded"

        implicitHeight: size
        implicitWidth: iconBlock.width + countLabel.implicitWidth + size * (rounded ? 0.7 : 0.5)
        radius: rounded ? height / 2 : 2
        color: root.look.colors.colorCountBackground
        border.width: rounded ? 1.5 : 1
        border.color: badge.color

        Rectangle {
            id: iconBlock
            width: parent.size
            height: parent.size
            radius: parent.rounded ? width / 2 : 2
            color: badge.color

            Kirigami.Icon {
                anchors.centerIn: parent
                width: parent.height * 0.65
                height: width
                source: badge.icon
                isMask: true
                color: root.contrastText(badge.color)
            }
        }

        PlasmaComponents.Label {
            textFormat: Text.PlainText
            id: countLabel
            anchors.left: iconBlock.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: badge.display || badge.count
            color: root.contrastText(root.look.colors.colorCountBackground)
            font.pixelSize: parent.size * 0.6
        }
    }

    // A row (or column, in a vertical panel) of count badges, one per non-zero count.
    component BadgeBar: GridLayout {
        id: bar
        property real badgeSize
        property bool vertical: false
        property bool showLogo: false
        readonly property int itemCount: root.visibleBadges.length + (showLogo ? 1 : 0)

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
            model: root.visibleBadges
            CountBadge {
                required property var modelData
                badge: modelData
                size: badgeSize
            }
        }
    }

    compactRepresentation: MouseArea {
        id: compact

        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        readonly property real badgeSize: Math.min(Kirigami.Units.iconSizes.smallMedium, vertical ? width : height)
        readonly property bool showBadges: root.login !== "" && root.visibleBadges.length > 0

        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) {
                root.refresh(false)
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
            showLogo: root.look.showLogo
            vertical: compact.vertical
            badgeSize: compact.badgeSize
            opacity: root.errorText ? 0.5 : 1
        }

        // While loading, on errors, or when nothing needs attention.
        Kirigami.Icon {
            anchors.centerIn: parent
            width: compact.badgeSize
            height: compact.badgeSize
            visible: !compact.showBadges
            source: root.look.showLogo && root.customLogo || Plasmoid.icon
            active: compact.containsMouse
            opacity: root.errorText || root.login === "" ? 0.5 : 1
        }
    }

    // One clickable line in the popup: optional status dot, title and a dimmed subtitle.
    component EntryRow: PlasmaComponents.ItemDelegate {
        property string title
        property string subtitle
        property string url
        property color dotColor: "transparent"
        property bool bold: false
        // Set for a release notification: the page is looked up from this API URL on click.
        property string releaseApiUrl: ""

        Layout.fillWidth: true
        onClicked: releaseApiUrl ? root.openRelease(releaseApiUrl, url) : Qt.openUrlExternally(url)

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
                spacing: 0
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: title
                    font.bold: bold
                    elide: Text.ElideRight
                }
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: subtitle
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
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

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30

        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                PlasmaExtras.Heading {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    level: 3
                    text: root.login ? "@" + root.login : i18n("GitHub Account")
                    elide: Text.ElideRight
                }

                PlasmaComponents.ToolButton {
                    icon.name: "mail-mark-read"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Mark all notifications read")
                    enabled: !root.loading && root.unreadNotifications.length > 0
                    onClicked: root.refresh(true)
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }

                PlasmaComponents.ToolButton {
                    icon.name: "internet-web-browser"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Open GitHub notifications")
                    onClicked: Qt.openUrlExternally("https://github.com/notifications")
                    PlasmaComponents.ToolTip.text: text
                    PlasmaComponents.ToolTip.visible: hovered
                }

                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents.AbstractButton.IconOnly
                    text: i18n("Refresh")
                    enabled: !root.loading
                    onClicked: root.refresh(false)
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
                visible: root.login !== ""
                badgeSize: Kirigami.Units.iconSizes.small * 1.25
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
            visible: root.errorText !== "" && root.login === ""
            iconName: "dialog-error"
            text: i18n("Could not reach GitHub")
            explanation: i18n("%1\n\nMake sure the gh CLI is installed and logged in (gh auth login).", root.errorText)
        }

        PlasmaComponents.ScrollView {
            id: scroll
            anchors.fill: parent
            // Long titles are elided instead of making the list scroll sideways.
            contentWidth: availableWidth
            // Never scroll sideways. An as-needed horizontal bar would also toggle with the vertical one,
            // which changes availableWidth: a binding loop on its "visible".
            PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff
            visible: root.login !== ""

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

                GroupHeader {
                    id: reviewsHeader
                    groupKey: "reviews"
                    visible: root.reviews.length > 0
                    text: root.reviewCount > root.reviews.length
        ? i18np("Review requested (showing %2 of %1)", "Review requested (showing %2 of %1)", root.reviewCount, root.reviews.length)
        : i18np("Review requested (%1)", "Review requested (%1)", root.reviewCount)
                }
                Repeater {
                    model: reviewsHeader.collapsed ? [] : root.reviews
                    EntryRow {
                        required property var modelData
                        title: modelData.title
                        subtitle: i18n("%1 #%2 by %3", modelData.repository.nameWithOwner, modelData.number,
                                       modelData.author ? modelData.author.login : i18n("unknown"))
                        url: modelData.url
                        dotColor: root.reviewsColor
                        bold: true
                    }
                }

                GroupHeader {
                    id: notificationsHeader
                    groupKey: "notifications"
                    text: root.moreNotifications
        ? i18n("Notifications (%1+ unread)", Logic.notificationLimit)
        : i18np("Notifications (%1 unread)", "Notifications (%1 unread)", root.unreadNotifications.length)
                }
                Repeater {
                    model: notificationsHeader.collapsed ? [] : root.notifications
                    EntryRow {
                        required property var modelData
                        title: modelData.subject.title
                        subtitle: i18n("%1 · %2 · %3", modelData.repository.full_name,
                                       modelData.reason.replace(/_/g, " "), root.relativeTime(modelData.updated_at))
                        url: root.notificationUrl(modelData)
                        releaseApiUrl: modelData.subject.type === "Release" && modelData.subject.url ? modelData.subject.url : ""
                        dotColor: modelData.unread ? Kirigami.Theme.highlightColor : "transparent"
                        bold: modelData.unread
                    }
                }
                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    Layout.margins: Kirigami.Units.largeSpacing
                    visible: root.notifications.length === 0 && !notificationsHeader.collapsed
                    horizontalAlignment: Text.AlignHCenter
                    opacity: 0.7
                    text: i18n("You're all caught up")
                }

                GroupHeader {
                    id: pullRequestsHeader
                    groupKey: "pullRequests"
                    visible: root.pullRequests.length > 0
                    text: root.prCount > root.pullRequests.length
        ? i18np("Your open pull requests (showing %2 of %1)", "Your open pull requests (showing %2 of %1)", root.prCount, root.pullRequests.length)
        : i18np("Your open pull requests (%1)", "Your open pull requests (%1)", root.prCount)
                }
                Repeater {
                    model: pullRequestsHeader.collapsed ? [] : root.pullRequests
                    EntryRow {
                        required property var modelData
                        title: (modelData.isDraft ? i18n("[Draft] ") : "") + modelData.title
                        subtitle: [i18n("%1 #%2", modelData.repo, modelData.number), root.ciText(modelData), root.prStatusText(modelData)]
                            .filter(part => part !== "").join(" · ")
                        url: Logic.rowUrl(modelData, modelData.url)
                        dotColor: root.ciColor(modelData.ci)
                    }
                }

                GroupHeader {
                    id: reposHeader
                    groupKey: "repos"
                    visible: Plasmoid.configuration.showRepos && root.shownRepos.length > 0
                    text: i18n("Recently pushed repositories")
                }
                Repeater {
                    model: Plasmoid.configuration.showRepos && !reposHeader.collapsed ? root.shownRepos : []
                    EntryRow {
                        required property var modelData
                        title: modelData.name
                        subtitle: i18n("%1 · pushed %2", root.ciText(modelData), root.relativeTime(modelData.pushedAt))
                        url: Logic.rowUrl(modelData, modelData.url + "/actions")
                        dotColor: root.ciColor(modelData.ci)
                    }
                }
            }
        }
    }
}
