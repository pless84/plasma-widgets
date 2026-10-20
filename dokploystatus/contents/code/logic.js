.pragma library
// The Dokploy Status widget's logic, kept free of Plasma and i18n so it can be unit-tested
// (tests/widgets/dokploystatus.test.mjs). main.qml imports it as Logic.

// Dokploy's statuses, worst first: error = last deployment failed, running = deployment in
// progress, done = deployed, idle = never deployed or stopped.
var statusOrder = ["error", "running", "done", "idle"]

function shellQuote(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'"
}

// A service's status as one of statusOrder; anything else (e.g. null) counts as idle.
function statusKey(service) {
    return statusOrder.includes(service.status) ? service.status : "idle"
}

// Every service in dokploy.py's projects, flattened.
function allServices(projects) {
    const all = []
    projects.forEach(p => p.environments.forEach(e => e.services.forEach(s => all.push(s))))
    return all
}

function countStates(services) {
    const counts = {}
    services.forEach(s => {
        const key = statusKey(s)
        counts[key] = (counts[key] || 0) + 1
    })
    return counts
}

// One group per environment that has services: {title, projectId, environmentId, services},
// sorted by `order` (status keys, worst first). The environment is named only when a project has more than one.
function groupServices(projects, order) {
    const list = []
    projects.forEach(p => p.environments.forEach(e => {
        if (e.services.length === 0) {
            return
        }
        list.push({
            title: p.environments.length > 1 ? p.name + " · " + e.name : p.name,
            projectId: p.id,
            environmentId: e.id,
            services: e.services.slice().sort((a, b) =>
                order.indexOf(statusKey(a)) - order.indexOf(statusKey(b)) || a.name.localeCompare(b.name)),
        })
    }))
    return list
}

function serviceUrl(serverUrl, group, service) {
    return serverUrl + "/dashboard/project/" + group.projectId + "/environment/" + group.environmentId
        + "/services/" + service.type + "/" + service.id
}

// Whole minutes between an ISO timestamp and now (a Date); null when there is no usable time.
function minutesSince(iso, now) {
    const t = iso ? Date.parse(iso) : NaN
    return isNaN(t) ? null : Math.max(0, Math.floor((now.getTime() - t) / 60000))
}

// "1m 32s" or "2h 5m": a duration in seconds.
function formatDuration(seconds) {
    const s = Math.round(seconds)
    if (s < 60) {
        return s + "s"
    }
    if (s < 3600) {
        return Math.floor(s / 60) + "m " + (s % 60) + "s"
    }
    return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
}

// The first 7 characters of a commit hash found in a deployment's description, or "".
function shortCommit(description) {
    const m = /\b[0-9a-f]{7,40}\b/i.exec(description || "")
    return m ? m[0].slice(0, 7) : ""
}

// What to say about an application's or compose stack's newest deployment, or null without one:
// {minutes (since it finished, else started, else was created), duration (seconds or null),
// title, commit, failed}.
function deploymentSummary(service, now) {
    const d = service.deployment
    if (!d) {
        return null
    }
    const started = Date.parse(d.startedAt || d.createdAt)
    const finished = Date.parse(d.finishedAt)
    return {
        minutes: minutesSince(d.finishedAt || d.startedAt || d.createdAt, now),
        duration: isNaN(started) || isNaN(finished) ? null : Math.max(0, (finished - started) / 1000),
        // A git deployment's title is the whole commit message; its first line is the summary.
        title: (d.title || "").trim().split("\n")[0].trim(),
        commit: shortCommit(d.description),
        failed: d.status === "error",
    }
}

// Why a failed service failed: its newest deployment's error message (first line), else its
// title; "" when unknown.
function failureReason(service) {
    const d = service.deployment
    if (!d || d.status !== "error") {
        return ""
    }
    const line = (d.errorMessage || "").trim().split("\n")[0].trim() || (d.title || "").trim()
    return line.length > 160 ? line.slice(0, 159) + "…" : line
}

// "never" for an idle application/compose stack that has no deployment, "stopped" for one that
// has (it was deployed, then stopped), "" when unknown or not applicable.
function idleDetail(service) {
    if (statusKey(service) !== "idle" || (service.type !== "application" && service.type !== "compose")) {
        return ""
    }
    return service.deployment === null ? "never" : service.deployment ? "stopped" : ""
}

// A database's backup state: {kind: "none" | "ok" | "failed" | "waiting", minutes}. A failed
// run's error message is never shown: it can hold credentials.
// "none" when no backup is switched on; "waiting" when one is on but has not run yet. The
// newest run over all its enabled backups counts.
function backupSummary(service, now) {
    const enabled = (service.backups || []).filter(b => b.enabled)
    if (enabled.length === 0) {
        return { kind: "none", minutes: null }
    }
    const runs = enabled.map(b => b.last).filter(r => r && r.status !== "running")
    if (runs.length === 0) {
        return { kind: "waiting", minutes: null }
    }
    const last = runs.reduce((a, b) => (b.createdAt || "") > (a.createdAt || "") ? b : a)
    return {
        kind: last.status === "error" ? "failed" : "ok",
        minutes: minutesSince(last.finishedAt || last.createdAt, now),
    }
}

// True when the services run on more than one server (a database's or deployment's server
// name; "" is the Dokploy host itself, and services of unknown server are ignored).
function multipleServers(services) {
    const names = {}
    services.forEach(s => {
        if (typeof s.server === "string") {
            names[s.server] = true
        }
    })
    return Object.keys(names).length > 1
}

// Databases whose newest backup run failed since the last check: {fresh, seen}. fresh holds
// {service, run, minutes} per database: the failed run itself and how long ago it finished (null
// without a usable time). seen is every failed run id now, to pass back in as previousSeen;
// nothing is fresh on the first check (previousSeen null).
function freshBackupFailures(services, previousSeen, now) {
    const seen = {}
    const fresh = []
    services.forEach(s => {
        const failed = (s.backups || []).filter(b => b.enabled && b.last && b.last.status === "error")
        failed.forEach(b => {
            const id = b.last.id || (s.id + ":" + b.last.createdAt)
            seen[id] = true
            if (previousSeen && !previousSeen[id] && !fresh.some(f => f.service === s)) {
                fresh.push({ service: s, run: b.last, minutes: now ? minutesSince(b.last.finishedAt || b.last.createdAt, now) : null })
            }
        })
    })
    return { fresh: fresh, seen: seen }
}

// Services whose deployment newly failed since the last check, and the statuses to remember.
// Nothing is fresh on the first check (previousStatus null).
function freshFailures(services, previousStatus) {
    const fresh = services.filter(s => previousStatus && s.status === "error" && previousStatus[s.id] !== "error")
    const statuses = {}
    services.forEach(s => statuses[s.id] = s.status)
    return { fresh: fresh, statuses: statuses }
}

// The badge states to show: those switched on in the settings (st.inPanel) with services in
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
    colorFailed: "error",
    colorDeploying: "active",
    colorDeployed: "ok",
    colorIdle: "neutral",
    colorCountBackground: "countBackground"
}
