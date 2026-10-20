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
