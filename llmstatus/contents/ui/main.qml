import QtQuick
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

    readonly property string codeDir: Qt.resolvedUrl("../code/").toString().replace("file://", "")
    // "ollama": an Ollama server. "lmstudio": an LM Studio server. Anything else (such as the
    // old "dashboard" source) counts as Ollama.
    readonly property bool fromLmStudio: Plasmoid.configuration.source === "lmstudio"
    readonly property string serverUrl: (fromLmStudio ? Plasmoid.configuration.lmstudioUrl : Plasmoid.configuration.ollamaUrl)
        .trim().replace(/\/+$/, "")
    // gpu.sh reads this computer's GPU, so it says nothing about a server on another host.
    readonly property bool readGpu: Plasmoid.configuration.showGpu && Logic.isLocalHost(serverUrl)

    // The status as an "llm" block (see logic.js), or null before the first check.
    property var llm: null
    // What Logic.llmChanges() returned last time; null until the first check.
    property var llmSnapshot: null
    // Seconds since the epoch at the last check.
    property real serverNow: 0
    property bool loaded: false
    property date lastChecked
    property string errorText: ""
    property bool loading: false
    // Counts checks, so replies to an older check (e.g. before the address changed) are ignored.
    property int checkId: 0
    // Replies gathered during an Ollama check (see refresh()): how many are still out, and each reply.
    property int pendingLeft: 0
    property var pendingVersion: null
    property int pendingVersionStatus: 0
    property var pendingPs: null
    property var pendingTags: null
    property var pendingGpu: null
    // LM Studio's /api/v1/models reply during an LM Studio check.
    property var pendingModels: null
    // What Logic.trackUsage() returned last time (Ollama and LM Studio): when each loaded model was last used.
    property var usage: null

    readonly property var servers: Logic.llmServers(llm)
    readonly property string llmState: Logic.llmState(llm)
    readonly property int loadedCount: Logic.loadedCount(llm)
    readonly property var gpu: llm ? llm.gpu : null
    readonly property bool hasGpuLoad: !!gpu && gpu.util !== null && gpu.util !== undefined
    // The Ollama or LM Studio server, whose loaded and installed models are listed.
    readonly property var modelServer: servers.length > 0 ? servers[0] : null
    readonly property var loadedModels: modelServer && modelServer.up ? modelServer.models : []
    readonly property var installedModels: modelServer && modelServer.up ? modelServer.installed : []
    readonly property bool badgeMode: root.look.badgeStyle !== "dot"

    // The panel badges: the status (GPU load, coloured by server state) and the loaded models.
    readonly property var statusBadge: llmState && Plasmoid.configuration.showStatusInPanel ? {
        key: "status",
        glyph: llmState === "down" ? "cross" : llmState === "busy" ? "play" : "check",
        roundGlyph: llmState === "down" ? "cross" : llmState === "busy" ? "play" : "check",
        color: stateColor(llmState),
        count: hasGpuLoad ? gpu.util + "%" : llmState === "down" ? i18n("Down") : i18n("Up")
    } : null
    readonly property var loadedBadge: llmState && llmState !== "down" && Plasmoid.configuration.showLoadedInPanel
        && (loadedCount > 0 || Plasmoid.configuration.showZeroInPanel) ? {
        key: "loaded", glyph: "layers", roundGlyph: "layers", color: stateColor("loaded"), count: loadedCount
    } : null
    readonly property var badges: [statusBadge, loadedBadge].filter(b => b)

    readonly property bool gpuHot: !!gpu && gpu.temp_c >= Logic.TEMP_WARN
    // Ollama's own share of the GPU memory: the card is shared with other programs. LM Studio doesn't report it.
    readonly property var ollamaVramGb: gpu && gpu.mem_total_gb && modelServer && modelServer.kind === "ollama"
        ? Logic.ollamaVramGb(loadedModels) : null
    // Programs other than Ollama and LM Studio using GPU memory, when a loaded model doesn't fit on the GPU completely.
    readonly property string spillText: {
        if (!gpu || !gpu.apps || gpu.apps.length === 0) return ""
        if (!loadedModels.some(m => { const p = Logic.gpuPercent(m); return p !== null && p < 100 })) return ""
        return i18n("Also using GPU memory: %1", gpu.apps.slice(0, 3).map(a => i18n("%1 %2 GB", a.name, a.used_gb)).join(", "))
    }

    readonly property string gpuText: {
        if (!gpu) return ""
        const parts = []
        if (hasGpuLoad) parts.push(i18n("GPU %1%", gpu.util))
        if (gpu.mem_total_gb) parts.push(i18n("%1 / %2 GB VRAM", gpu.mem_used_gb, gpu.mem_total_gb))
        if (ollamaVramGb !== null) parts.push(i18n("Ollama %1 GB", ollamaVramGb))
        if (gpu.temp_c !== null && gpu.temp_c !== undefined) parts.push(i18n("%1 °C", gpu.temp_c))
        if (gpu.power_w !== null && gpu.power_w !== undefined) {
            parts.push(gpu.power_limit_w ? i18n("%1 / %2 W", gpu.power_w, gpu.power_limit_w) : i18n("%1 W", gpu.power_w))
        }
        if (gpu.name) parts.push(gpu.name)
        return parts.join(" · ")
    }

    readonly property string summary: {
        if (!serverUrl) return fromLmStudio ? i18n("Set the LM Studio address in the settings") : i18n("Set the Ollama address in the settings")
        if (!loaded) return i18n("Checking LLMs…")
        const down = servers.filter(s => !s.up).length
        if (down > 0) return servers.length === 1 ? i18n("%1 is down", servers[0].name) : i18np("%1 LLM server down", "%1 LLM servers down", down)
        const models = loadedCount > 0 ? i18np("%1 model loaded", "%1 models loaded", loadedCount) : i18n("No model loaded")
        return hasGpuLoad ? (llmState === "busy" ? i18n("%1 · GPU busy %2%", models, gpu.util) : i18n("%1 · GPU %2%", models, gpu.util)) : models
    }

    // White or near-black, whichever reads better on the given background colour.
    function contrastText(background) {
        const c = Qt.color(background)
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6 ? "#202020" : "white"
    }

    function stateColor(key) {
        switch (key) {
        case "down": return root.look.colors.colorDown
        case "busy": return root.look.colors.colorBusy
        case "idle": return root.look.colors.colorIdle
        case "loaded": return root.look.colors.colorLoaded
        default: return Kirigami.Theme.disabledTextColor
        }
    }

    // A loaded model's details: "12.2B · Q4_K_M · ctx 8k".
    function modelDetailsText(model) {
        return Logic.modelDetails(model).concat(model.context ? [i18n("ctx %1", Logic.shortCount(model.context))] : []).join(" · ")
    }

    // "unloads in 4m", or "stays loaded" for models kept in memory indefinitely.
    function unloadText(expires) {
        // Ollama sends nanoseconds (".837530123"); Date.parse wants at most milliseconds.
        const left = Date.parse(String(expires).replace(/(\.\d{3})\d+/, "$1")) / 1000 - serverNow
        if (isNaN(left)) return ""
        return left > 365 * 86400 ? i18n("stays loaded") : i18n("unloads in %1", Logic.formatDuration(left))
    }

    // GET a JSON document; calls done(parsed or null, HTTP status).
    function getJson(url, done) {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) {
                return
            }
            let data = null
            if (xhr.status === 200) {
                try {
                    data = JSON.parse(xhr.responseText)
                } catch (e) {
                    data = null
                }
            }
            done(data, xhr.status)
        }
        xhr.open("GET", url)
        xhr.send()
    }

    function refresh() {
        if (!serverUrl || loading) {
            return
        }
        loading = true
        const id = ++checkId
        checkTimeout.restart()
        pendingVersion = null
        pendingVersionStatus = 0
        pendingPs = null
        pendingTags = null
        pendingModels = null
        pendingGpu = null
        if (readGpu) {
            gpuReader.connectSource("sh " + Look.shellQuote(codeDir + "gpu.sh") + " # " + id)
        }
        if (fromLmStudio) {
            // LM Studio: one API call (its model list says which are loaded), plus the GPU when it's read.
            pendingLeft = readGpu ? 2 : 1
            getJson(serverUrl + "/api/v1/models", (data, status) => {
                if (id !== checkId) return
                pendingModels = data
                // Stands in for Ollama's /api/version: whether the server answered.
                pendingVersion = data && Array.isArray(data.models) ? data : null
                pendingVersionStatus = status
                serverAnswered(id)
            })
            return
        }
        // Ollama: three API calls, plus the GPU when it's read; apply once all have answered.
        pendingLeft = readGpu ? 4 : 3
        getJson(serverUrl + "/api/version", (data, status) => {
            if (id !== checkId) return
            pendingVersion = data
            pendingVersionStatus = status
            serverAnswered(id)
        })
        getJson(serverUrl + "/api/ps", data => {
            if (id !== checkId) return
            pendingPs = data
            serverAnswered(id)
        })
        getJson(serverUrl + "/api/tags", data => {
            if (id !== checkId) return
            pendingTags = data
            serverAnswered(id)
        })
    }

    function gpuAnswered(id, text) {
        if (id !== checkId) return
        pendingGpu = Logic.parseGpu(text)
        serverAnswered(id)
    }

    // One reply of an Ollama or LM Studio check is in; once all are, turn them into the status.
    function serverAnswered(id) {
        if (id !== checkId || --pendingLeft > 0) return
        finishCheck()
        applyServer(pendingVersion ? "" : pendingVersionStatus === 200 ? i18n("Could not read the reply from %1", serverUrl)
            : pendingVersionStatus ? i18n("HTTP error %1", pendingVersionStatus) : i18n("Can't reach %1", serverUrl))
    }

    function finishCheck() {
        checkTimeout.stop()
        loading = false
        lastChecked = new Date()
    }

    function applyServer(error) {
        errorText = ""
        serverNow = Date.now() / 1000
        apply(fromLmStudio ? Logic.fromLmStudio(pendingModels, pendingGpu, error, serverNow)
            : Logic.fromOllama(pendingVersion, pendingPs, pendingTags, pendingGpu, error))
    }

    function apply(block) {
        const result = Logic.llmChanges(block, llmSnapshot)
        // A failed model list says nothing about the models, so it must not wipe what was tracked.
        const server = block.ollama || block.lmstudio
        const listed = fromLmStudio ? pendingModels : pendingPs
        usage = server.up ? Logic.trackUsage(usage, listed ? server.models : null, serverNow) : null
        llm = block
        llmSnapshot = result.snapshot
        loaded = true
        if (result.wentDown.length > 0 && Plasmoid.configuration.notifyOnDown) {
            notification.title = i18np("%1 LLM server down", "%1 LLM servers down", result.wentDown.length)
            notification.text = result.wentDown.map(s => s.error ? s.name + " · " + s.error : s.name).join("\n")
            notification.sendEvent()
        }
    }

    function reset() {
        checkId++
        checkTimeout.stop()
        loaded = false
        llm = null
        llmSnapshot = null
        usage = null
        errorText = ""
        loading = false
        refresh()
    }

    onServerUrlChanged: reset()
    onReadGpuChanged: reset()

    // Runs gpu.sh. Each run ends in "# <check number>", which makes it a new command every time
    // and says which check the output belongs to.
    P5Support.DataSource {
        id: gpuReader
        engine: "executable"
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.gpuAnswered(parseInt(sourceName.split("# ").pop()), data.stdout || "")
        }
    }

    // Gives up on a check that hasn't finished after 20 seconds (e.g. a server that accepts the
    // connection but never answers), so the widget keeps checking.
    Timer {
        id: checkTimeout
        interval: 20000
        onTriggered: {
            if (!root.loading) return
            root.checkId++
            root.finishCheck()
            root.applyServer(root.pendingVersion ? "" : i18n("No answer from %1", root.serverUrl))
        }
    }

    Plasmoid.icon: "cpu"

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

    Plasmoid.status: llmState === "down" ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus

    toolTipMainText: i18n("LLM Status")
    toolTipSubText: errorText || [summary, gpuText].filter(t => t).join("\n")

    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 12

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh")
            icon.name: "view-refresh"
            onTriggered: root.refresh()
        }
    ]

    Notification {
        id: notification
        componentName: "plasma_workspace"
        eventId: "notification"
        iconName: "cpu"
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
        // Stacked layers: models held in memory.
        layers: { stroke: "M 50 22 L 80 38 L 50 54 L 20 38 Z M 20 54 L 50 70 L 80 54 M 20 68 L 50 84 L 80 68" },
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

    // A row (or column, in a vertical panel) of badges ({glyph, roundGlyph, color, count}).
    component BadgeBar: GridLayout {
        id: bar
        property real badgeSize
        property bool vertical: false
        property var badges: root.badges
        property bool showLogo: false
        readonly property int itemCount: badges.length + (showLogo ? 1 : 0)

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
            model: bar.badges
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
        readonly property bool showBadges: root.badgeMode && root.badges.length > 0

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
                color: root.errorText ? root.stateColor("unknown") : root.stateColor(root.llmState)
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

    // A coloured dot, as in the other widgets' lists.
    component StateDot: Rectangle {
        Layout.preferredWidth: Kirigami.Units.smallSpacing * 2
        Layout.preferredHeight: width
        radius: width / 2
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
                    color: root.errorText ? root.stateColor("unknown") : root.stateColor(root.llmState)
                }

                PlasmaExtras.Heading {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    level: 3
                    text: root.summary
                    elide: Text.ElideRight
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
                visible: root.badgeMode && root.badges.length > 0
                badgeSize: Kirigami.Units.iconSizes.small * 1.25
            }

            // GPU load and memory, in the busy colour while the GPU runs hot.
            PlasmaComponents.Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                Layout.topMargin: Kirigami.Units.smallSpacing
                visible: root.gpuText !== ""
                opacity: 0.7
                font: Kirigami.Theme.smallFont
                elide: Text.ElideRight
                color: root.gpuHot ? root.stateColor("busy") : Kirigami.Theme.textColor
                text: root.gpuText
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
            // Long names are elided instead of making the list scroll sideways.
            contentWidth: availableWidth
            // Never scroll sideways. An as-needed horizontal bar would also toggle with the vertical one,
            // which changes availableWidth: a binding loop on its "visible".
            PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff

            ColumnLayout {
                width: scroll.availableWidth
                spacing: Kirigami.Units.smallSpacing

                // ---- The servers ----
                Repeater {
                    // Hidden while the server can't be reached, rather than showing the last known state.
                    model: root.loaded && !root.errorText ? root.servers : []

                    PlasmaComponents.ItemDelegate {
                        id: serverItem
                        required property var modelData
                        readonly property color stateColor: root.stateColor(modelData.up ? "idle" : "down")

                        Layout.fillWidth: true

                        contentItem: ColumnLayout {
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                StateDot {
                                    color: serverItem.stateColor
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: serverItem.modelData.name
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    text: serverItem.modelData.up ? i18n("Up") : i18n("Down")
                                    color: serverItem.stateColor
                                }
                            }

                            // Down: why.
                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                visible: !serverItem.modelData.up
                                text: serverItem.modelData.error || i18n("Not responding")
                            }

                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                text: {
                                    const s = serverItem.modelData
                                    return [
                                        s.version ? "v" + s.version : "",
                                        root.serverUrl,
                                        s.up && s.installed.length > 0
                                            ? i18np("%1 model installed", "%1 models installed", s.installed.length) : "",
                                    ].filter(t => t).join(" · ")
                                }
                            }
                        }
                    }
                }

                // ---- Ollama's or LM Studio's loaded models ----
                GroupHeader {
                    id: loadedHeader
                    visible: root.modelServer !== null && root.modelServer.up && !root.errorText
                    groupKey: "loaded"
                    text: i18n("Loaded models")
                }

                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    visible: loadedHeader.visible && !loadedHeader.collapsed && root.loadedModels.length === 0
                    opacity: 0.7
                    text: root.modelServer ? i18n("No model loaded. %1 loads one on its first request.", root.modelServer.name) : ""
                    wrapMode: Text.WordWrap
                }

                PlasmaComponents.Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.largeSpacing
                    visible: loadedHeader.visible && !loadedHeader.collapsed && root.spillText !== ""
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                    text: root.spillText
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: loadedHeader.collapsed ? [] : root.loadedModels

                    PlasmaComponents.ItemDelegate {
                        id: modelItem
                        required property var modelData
                        readonly property var onGpu: Logic.gpuPercent(modelData)
                        readonly property real usedAt: root.usage && root.usage.used[modelData.name] || 0
                        readonly property bool inUse: Logic.modelInUse(root.usage, modelData.name, root.serverNow)

                        Layout.fillWidth: true

                        contentItem: ColumnLayout {
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                StateDot {
                                    color: root.stateColor("loaded")
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    Layout.fillWidth: true
                                    text: modelItem.modelData.name
                                    font.bold: true
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents.Label {
                                    textFormat: Text.PlainText
                                    text: i18n("%1 GB", modelItem.modelData.size_gb)
                                }
                            }

                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                text: [
                                    modelItem.onGpu === null ? "" : modelItem.onGpu >= 100 ? i18n("all on GPU")
                                        : modelItem.onGpu <= 0 ? i18n("all on CPU") : i18n("%1% on GPU", modelItem.onGpu),
                                    modelItem.inUse ? i18n("in use") : "",
                                    modelItem.usedAt && !modelItem.inUse ? i18n("used ~%1 ago", Logic.formatDuration(root.serverNow - modelItem.usedAt)) : "",
                                    modelItem.modelData.expires ? root.unloadText(modelItem.modelData.expires) : "",
                                ].filter(t => t).join(" · ")
                            }

                            PlasmaComponents.Label {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                visible: text !== ""
                                text: root.modelDetailsText(modelItem.modelData)
                            }
                        }
                    }
                }

                // ---- Ollama's or LM Studio's installed models ----
                GroupHeader {
                    id: installedHeader
                    visible: root.installedModels.length > 0 && !root.errorText
                    groupKey: "installed"
                    text: i18np("Installed model (%1)", "Installed models (%1)", root.installedModels.length)
                }

                Repeater {
                    model: installedHeader.collapsed ? [] : root.installedModels

                    RowLayout {
                        required property var modelData

                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.largeSpacing
                        Layout.rightMargin: Kirigami.Units.largeSpacing
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaComponents.Label {
                            textFormat: Text.PlainText
                            Layout.fillWidth: true
                            text: modelData.name
                            elide: Text.ElideRight
                        }
                        PlasmaComponents.Label {
                            textFormat: Text.PlainText
                            text: Logic.modelDetails(modelData).concat([i18n("%1 GB", modelData.size_gb)]).join(" · ")
                            opacity: 0.7
                        }
                    }
                }

                PlasmaExtras.PlaceholderMessage {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.gridUnit * 2
                    visible: !root.loaded || root.servers.length === 0 || root.errorText !== ""
                    iconName: root.errorText ? "network-disconnect" : root.loading ? "view-refresh" : "cpu"
                    text: root.errorText ? root.errorText : root.summary
                }
            }
        }
    }
}
