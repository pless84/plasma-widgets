.pragma library
// The GitHub Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/githubstatus.test.mjs). main.qml imports it as Logic.

// Plain text from an update body: HTML tags removed, <br> and paragraph ends kept as line breaks.
function stripHtml(html) {
    return String(html || "")
        .replace(/<br\s*\/?>/gi, "\n")
        .replace(/<\/p>/gi, "\n")
        .replace(/<[^>]*>/g, "")
        .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
        .replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&amp;/g, "&")
        .replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n")
        .trim()
}

// Text on one line, cut to max characters with an ellipsis.
function oneLine(text, max) {
    const flat = String(text || "").replace(/\s+/g, " ").trim()
    return flat.length > max ? flat.slice(0, max - 1).trimEnd() + "…" : flat
}

// An incident or maintenance from the API plus: affects (component names), started (ISO time) and
// update ({id, status, body, at} of the newest update, or null).
function parseEvent(item) {
    const latest = (item.incident_updates || [])[0]
    return Object.assign({}, item, {
        affects: (item.components || []).map(c => c.name),
        started: item.started_at || item.created_at,
        update: latest ? {
            id: latest.id,
            status: latest.status,
            body: stripHtml(latest.body),
            at: latest.display_at || latest.created_at,
        } : null,
    })
}

// githubstatus.com's summary.json -> {indicator, summary, components, incidents, maintenances, upcoming}
function parseSummary(data) {
    const maintenance = data.scheduled_maintenances || []
    return {
        indicator: data.status.indicator,
        summary: data.status.description,
        // Skip group headers and the "Visit www.githubstatus.com…" placeholder.
        components: data.components.filter(c => !c.group && !c.name.startsWith("Visit ")),
        incidents: data.incidents.map(parseEvent),
        maintenances: maintenance.filter(m => m.status === "in_progress").map(parseEvent),
        upcoming: maintenance.filter(m => m.status === "scheduled").map(parseEvent),
    }
}

// Remembered state of the open incidents, {id: {name, status}}.
function incidentSnapshot(incidents) {
    const snapshot = {}
    incidents.forEach(i => snapshot[i.id] = { name: i.name, status: i.status })
    return snapshot
}

// What happened to the incidents since the previous snapshot: {events, next}. Each event is
// {kind: "new" | "status" | "resolved", incident}. summary.json only lists open incidents, so one
// that disappeared is resolved. No events on the first check (previous is null).
function incidentChanges(previous, incidents) {
    const next = incidentSnapshot(incidents)
    const events = []
    if (previous) {
        incidents.forEach(i => {
            if (!previous[i.id]) {
                events.push({ kind: "new", incident: i })
            } else if (previous[i.id].status !== i.status) {
                events.push({ kind: "status", incident: i })
            }
        })
        Object.keys(previous).filter(id => !next[id]).forEach(id => {
            events.push({ kind: "resolved", incident: { id: id, name: previous[id].name, status: "resolved", update: null, affects: [] } })
        })
    }
    return { events: events, next: next }
}

// Whether an ISO time falls on the same calendar day (local time) as now.
function isToday(iso, now) {
    const d = new Date(iso)
    const n = now || new Date()
    return d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate()
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
