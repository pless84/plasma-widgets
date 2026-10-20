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

// sentry.py's counts -> {new, open, archived, resolved, regressed}. "open" is unresolved but not
// new, so those four badges add up to the total; "regressed" is a subset of them.
function countStates(counts) {
    const c = counts || {}
    const fresh = c.new || 0
    return { new: fresh, open: Math.max((c.unresolved || 0) - fresh, 0), archived: c.archived || 0, resolved: c.resolved || 0, regressed: c.regressed || 0 }
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

// Unresolved issues that have regressed since the last check: Sentry calls them "regressed",
// they were seen before (so they aren't "new"), and they weren't regressed in the previous
// list (prevSubstatus: id -> substatus, null on the first check). This covers an issue that
// was resolved and came back, and one that was absent from the previous list.
function regressedIssues(issues, seenIds, prevSubstatus) {
    if (!seenIds || !prevSubstatus) return []
    return issues.filter(i => i.substatus === "regressed" && seenIds[i.id] && prevSubstatus[i.id] !== "regressed")
}

// id -> substatus of the given issues, to compare with at the next check. Earlier entries
// (prev) are kept for issues missing from this list, so a regressed issue that drops off the
// fetched pages and returns is not reported as regressed again; an issue seen now with another
// substatus replaces its entry.
function substatusById(issues, prev) {
    const map = Object.assign({}, prev || {})
    issues.forEach(i => map[i.id] = i.substatus || "")
    return map
}

// Which issue state's colour (see main.qml's issueStates keys) the row dot takes: fatal and error
// issues the "new" colour, warnings the "open" colour, anything milder the "archived" (grey) one.
// Newer Sentry also sends a priority; "high" lifts an issue to at least error.
function severityState(issue) {
    const level = issue.level
    if (level === "fatal" || level === "error" || issue.priority === "high") return "new"
    if (level === "info" || level === "debug" || level === "sample") return "archived"
    return "open"
}

// The tags to show on a row, as keys for the UI to label: fatal, regressed, escalating, unhandled.
function issueTags(issue) {
    const tags = []
    if (issue.level === "fatal") tags.push("fatal")
    if (issue.substatus === "regressed" || issue.substatus === "escalating") tags.push(issue.substatus)
    if (issue.isUnhandled === true) tags.push("unhandled")
    return tags
}

// The issue's events in the last 24 hours as a number, or null when Sentry sent no stats.
function events24h(issue) {
    return typeof issue.events24h === "number" ? issue.events24h : null
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
    colorRegressed: "attention",
    colorCountBackground: "countBackground"
}
