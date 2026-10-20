.pragma library
// The Sentry Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/sentrystatus.test.mjs). main.qml imports it as Logic.

// An unresolved issue counts as new when it was first seen within this many hours.
var newWithinHours = 24

function shellQuote(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'"
}

function isNew(issue, now) {
    return now - new Date(issue.firstSeen).getTime() < newWithinHours * 3600 * 1000
}

// sentry.py's counts -> {new, open, archived, resolved}. "open" is unresolved but not new, so the
// badges add up to the total.
function countStates(counts) {
    const c = counts || {}
    const fresh = c.new || 0
    return { new: fresh, open: Math.max((c.unresolved || 0) - fresh, 0), archived: c.archived || 0, resolved: c.resolved || 0 }
}

// Unresolved issues grouped by project, as [{name, issues}], the most recently active project
// first; issues keep sentry.py's order (most recently seen first).
function groupByProject(issues) {
    const groups = []
    const byName = {}
    issues.forEach(i => {
        const name = i.project || ""
        if (!byName[name]) {
            byName[name] = { name: name, issues: [] }
            groups.push(byName[name])
        }
        byName[name].issues.push(i)
    })
    const latest = g => Math.max.apply(null, g.issues.map(i => new Date(i.lastSeen).getTime()))
    return groups.sort((a, b) => latest(b) - latest(a))
}

// The issue's page: Sentry's permalink when it is an http(s) link, else one built from the server.
function issueUrl(serverUrl, organization, issue) {
    if (/^https?:\/\/\S+$/i.test(issue.permalink || "")) {
        return issue.permalink
    }
    return serverUrl + "/organizations/" + encodeURIComponent(organization) + "/issues/" + issue.id + "/"
}

// The organization's issue list on the server.
function issuesPageUrl(serverUrl, organization) {
    return serverUrl + "/organizations/" + encodeURIComponent(organization) + "/issues/"
}

// How long ago an ISO time was, as {unit: "minute" | "hour" | "day", count}, for i18np.
function age(iso, now) {
    const minutes = Math.round((now - new Date(iso).getTime()) / 60000)
    if (minutes < 60) return { unit: "minute", count: Math.max(minutes, 1) }
    const hours = Math.round(minutes / 60)
    if (hours < 24) return { unit: "hour", count: hours }
    return { unit: "day", count: Math.round(hours / 24) }
}

// Unresolved issues not seen before, and the ids to remember. Earlier ids are kept, so an issue
// that's resolved and comes back isn't "new" again. Nothing is fresh on the first check (seenIds null).
function freshIssues(issues, seenIds) {
    const fresh = issues.filter(i => seenIds && !seenIds[i.id])
    const seen = {}
    issues.forEach(i => seen[i.id] = true)
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
    colorArchived: "neutral",
    colorResolved: "ok",
    colorCountBackground: "countBackground"
}
