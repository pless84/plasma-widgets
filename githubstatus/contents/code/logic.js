.pragma library
// The GitHub Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/githubstatus.test.mjs). main.qml imports it as Logic.

// githubstatus.com's summary.json -> {indicator, summary, components, incidents, maintenances}
function parseSummary(data) {
    return {
        indicator: data.status.indicator,
        summary: data.status.description,
        // Skip group headers and the "Visit www.githubstatus.com…" placeholder.
        components: data.components.filter(c => !c.group && !c.name.startsWith("Visit ")),
        incidents: data.incidents,
        maintenances: data.scheduled_maintenances.filter(m => m.status === "in_progress"),
    }
}

// Components per status, e.g. {operational: 10, partial_outage: 1}
function countStates(components) {
    const counts = {}
    components.forEach(c => counts[c.status] = (counts[c.status] || 0) + 1)
    return counts
}

function visibleComponents(components, showOperational) {
    return showOperational ? components : components.filter(c => c.status !== "operational")
}

// Whether a check's overall indicator (none, minor, major, critical, maintenance) is worth a
// notification: it changed, and this isn't the first check.
function indicatorChanged(previous, current) {
    return previous !== "unknown" && previous !== current
}

// The badge states to show: those switched on in the settings (st.inPanel) with components in
// them, or all switched-on ones when showZero is set.
function panelStates(states, counts, showZero) {
    return states.filter(st => st.inPanel && (showZero || (counts[st.key] || 0) > 0))
}

function visibleStates(states, counts) {
    return states.filter(st => (counts[st.key] || 0) > 0)
}

// The collapsed groups list with key added, or removed if it was there
function toggled(list, key) {
    return list.includes(key) ? list.filter(k => k !== key) : list.concat([key])
}

// Which shared look colour role (see look.js) each colour setting follows when the widget
// uses the shared look.
var colorRoles = {
    colorMajorOutage: "error",
    colorPartialOutage: "attention",
    colorDegraded: "warning",
    colorMaintenance: "info",
    colorOperational: "ok",
    colorCountBackground: "countBackground"
}
