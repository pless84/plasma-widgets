.pragma library
// The Bugsink Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/bugsinkstatus.test.mjs). main.qml imports it as Logic.

// An open issue counts as new when it was first seen within this many hours.
var newWithinHours = 24

function shellQuote(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'"
}

function isNew(issue, now) {
    return now - new Date(issue.first_seen).getTime() < newWithinHours * 3600 * 1000
}

// bugsink.py's projects -> {new, open, muted, resolved}
function countStates(projects, now) {
    const counts = { new: 0, open: 0, muted: 0, resolved: 0 }
    projects.forEach(p => {
        p.open.forEach(i => counts[isNew(i, now) ? "new" : "open"]++)
        counts.muted += p.muted
        counts.resolved += p.resolved
    })
    return counts
}

// Projects with open issues, most recently active first.
function activeProjects(projects) {
    return projects.filter(p => p.open.length > 0)
        .sort((a, b) => new Date(b.open[0].last_seen) - new Date(a.open[0].last_seen))
}

function issueUrl(serverUrl, issue) {
    return serverUrl + "/issues/issue/" + issue.id + "/event/last/"
}

// "KeyError: 'user'", or "" when the issue has neither type nor value.
function issueTitle(issue) {
    return [issue.calculated_type, issue.calculated_value].filter(t => t).join(": ")
}

// How long ago an ISO time was, as {unit: "minute" | "hour" | "day", count}, for i18np.
function age(iso, now) {
    const minutes = Math.round((now - new Date(iso).getTime()) / 60000)
    if (minutes < 60) return { unit: "minute", count: Math.max(minutes, 1) }
    const hours = Math.round(minutes / 60)
    if (hours < 24) return { unit: "hour", count: hours }
    return { unit: "day", count: Math.round(hours / 24) }
}

// Open issues not seen before, as [{issue, project}], and the ids to remember. Earlier ids are
// kept, so an issue that's resolved and reopened isn't "new" again. Nothing is fresh on the
// first check (seenIds null).
function freshIssues(projects, seenIds) {
    const open = []
    projects.forEach(p => p.open.forEach(i => open.push({ issue: i, project: p.name })))
    const fresh = open.filter(o => seenIds && !seenIds[o.issue.id])
    const seen = {}
    open.forEach(o => seen[o.issue.id] = true)
    if (seenIds) {
        Object.keys(seenIds).forEach(id => seen[id] = true)
    }
    return { fresh: fresh, seen: seen }
}

// The badge states to show: those switched on in the settings (st.inPanel) with issues in
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
    colorNew: "error",
    colorOpen: "warning",
    colorMuted: "neutral",
    colorResolved: "ok",
    colorCountBackground: "countBackground"
}
